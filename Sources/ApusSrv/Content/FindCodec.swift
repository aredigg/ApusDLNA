import AVFoundation

public enum FindCodec {
    public static func videoCodec(atPath path: String) async -> VideoCodec? {
        let asset: AVAsset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard
            let track = try? await asset.loadTracks(withMediaType: .video).first,
            let descriptions = try? await track.load(.formatDescriptions),
            let desc = descriptions.first
        else { return nil }

        let codecType: FourCharCode = CMFormatDescriptionGetMediaSubType(desc)
        return VideoCodec(codecType: codecType)
    }

    public static func audioCodec(atPath path: String) async -> AudioCodec? {
        let asset: AVAsset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard
            let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let descriptions = try? await track.load(.formatDescriptions),
            let desc = descriptions.first
        else { return nil }
        let codecType: FourCharCode = CMFormatDescriptionGetMediaSubType(desc)
        return AudioCodec(codecType: codecType)
    }

    public static func videoDimensions(atPath path: String) async -> (Int, Int)? {
        let asset: AVAsset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard
            let track = try? await asset.loadTracks(withMediaType: .video).first,
            let size = try? await track.load(.naturalSize)
        else { return nil }
        return (Int(size.width), Int(size.height))
    }

    public static func duration(atPath path: String) async -> Double? {
        let asset: AVAsset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds: Float64 = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }
}
