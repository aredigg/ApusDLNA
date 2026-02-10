import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

public actor Transcoder {

    public init() {}

    public func transcode(
        path: String,
        codec: VideoCodec
    ) -> AsyncStream<Data> {
        let inputURL = URL(fileURLWithPath: path)
        let (stream, continuation) =
            AsyncStream<Data>.makeStream()

        Task.detached(priority: .userInitiated) {
            try await Self.performTranscode(
                from: inputURL,
                codec: codec,
                continuation: continuation
            )
            continuation.finish()
        }

        return stream
    }

    private static func performTranscode(
        from inputURL: URL,
        codec: VideoCodec,
        continuation: AsyncStream<Data>
            .Continuation
    ) async throws {
        print("performTranscode")
        let asset = AVURLAsset(url: inputURL)

        guard
            let videoTrack =
                try await asset
                .loadTracks(withMediaType: .video).first
        else { return }

        let audioTrack =
            try? await asset
            .loadTracks(withMediaType: .audio).first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let dataRate = try await videoTrack.load(.estimatedDataRate)

        let reader = try AVAssetReader(asset: asset)

        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        reader.add(videoReaderOutput)

        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let aro = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            aro.alwaysCopiesSampleData = false
            reader.add(aro)
            audioReaderOutput = aro
        }

        let segmentDelegate = SegmentDelegate(
            continuation: continuation
        )
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.delegate = segmentDelegate
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: 1,
            preferredTimescale: 600
        )
        writer.initialSegmentStartTime = .zero

        let targetBitRate: Int =
            switch codec {
            case .av01:
                dataRate > 0 ? Int(dataRate) : 5_000_000
            case .hevc:
                dataRate > 0 ? Int(dataRate) : 5_000_000
            default:
                0
            }

        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(naturalSize.width),
                AVVideoHeightKey: Int(naturalSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: targetBitRate,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                    AVVideoProfileLevelKey:
                        AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: true,
                ] as [String: any Sendable],
            ]
        )
        videoWriterInput.expectsMediaDataInRealTime = false
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let awi = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000,
                ]
            )
            awi.expectsMediaDataInRealTime = false
            writer.add(awi)
            audioWriterInput = awi
        }

        reader.startReading()
        print(reader.error.debugDescription)
        writer.startWriting()
        print(writer.error.debugDescription)
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(
            label: "com.jackalworks.apus-media.transcoder",
            qos: .userInitiated
        )

        let videoPair = UncheckedBox(
            value: (videoReaderOutput, videoWriterInput)
        )

        let audioPair:
            UncheckedBox<
                (AVAssetReaderTrackOutput, AVAssetWriterInput)
            >? =
                if let audioReaderOutput, let audioWriterInput {
                    UncheckedBox(
                        value: (audioReaderOutput, audioWriterInput)
                    )
                } else {
                    nil
                }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.drainSamples(
                    from: videoPair.value.0,
                    to: videoPair.value.1,
                    on: queue
                )
            }

            if let audioPair {
                group.addTask {
                    await Self.drainSamples(
                        from: audioPair.value.0,
                        to: audioPair.value.1,
                        on: queue
                    )
                }
            }

            await group.waitForAll()
        }

        await writer.finishWriting()
    }

    private static func drainSamples(
        from output: AVAssetReaderTrackOutput,
        to input: AVAssetWriterInput,
        on queue: DispatchQueue
    ) async {
        let pair = UncheckedBox(value: (output, input))

        await withCheckedContinuation { continuation in
            pair.value.1.requestMediaDataWhenReady(on: queue) {
                let (output, input) = pair.value
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                    } else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

private final class SegmentDelegate:
    NSObject,
    AVAssetWriterDelegate,
    @unchecked Sendable
{
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        continuation.yield(segmentData)
    }
}
