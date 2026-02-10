import Foundation

public actor Transcoder {

    public enum Profile: Sendable {
        case av01
    }

    public init() {}

    public func transcode(path: String, profile: Profile) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                let process: Process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                switch profile {
                case .av01:
                    process.arguments = [
                        "ffmpeg", "-i", path,
                        "-c:v", "libx264",
                        "-preset", "fast",
                        "-c:a", "aac",
                        "-f", "mpegts",
                        "pipe:1",
                    ]
                }
                let stdout: Pipe = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.finish()
                    return
                }
                let handle: FileHandle = stdout.fileHandleForReading
                var empty: Bool = false
                while !empty {
                    let chunk: Data = handle.readData(ofLength: 64 * 1024)
                    continuation.yield(chunk)
                    empty = chunk.isEmpty
                }
                process.waitUntilExit()
                continuation.finish()
            }
        }
    }
}
