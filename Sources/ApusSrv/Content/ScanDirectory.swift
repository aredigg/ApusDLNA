import AVFoundation
import Foundation

public actor ScanDirectory {
    private var items: [String: MediaItem] = [:]
    private var children: [String: [String]] = [:]
    private let maxConcurrentTasks = 32

    public init() {
        items["0"] = MediaItem(
            id: "0",
            parentID: "None",
            title: "Root",
            isContainer: true
        )
        children["0"] = []
    }

    public func addItem(_ item: MediaItem) {
        items[item.id] = item
        children[item.parentID, default: []].append(item.id)
    }

    public func browse(
        objectID: String,
        flag: String,
        startIndex: Int,
        requestedCount: Int
    ) -> (items: [MediaItem], totalMatches: Int) {
        if flag == "BrowseMetadata" {
            if let item: MediaItem = items[objectID] {
                return ([item], 1)
            }
            return ([], 0)
        }
        let childIDs = children[objectID] ?? []
        let total = childIDs.count
        let count = requestedCount == 0 ? total : requestedCount
        guard startIndex < total else { return ([], total) }
        let slice =
            childIDs
            .dropFirst(startIndex)
            .prefix(count)
            .compactMap { items[$0] }
        return (slice, total)
    }

    public func item(for id: String) -> MediaItem? {
        items[id]
    }

    public func scan(directory: String, parentID: String = "0") async throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: directory).sorted()
        var filesToProcess: [String] = []
        for name in contents {
            if name.hasPrefix(".") { continue }
            let fullPath = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    let folder = MediaItem(
                        id: fullPath,
                        parentID: parentID,
                        title: name,
                        isContainer: true
                    )
                    addItem(folder)
                    try await scan(directory: fullPath, parentID: fullPath)
                } else {
                    filesToProcess.append(name)
                }
            }
        }
        await withTaskGroup(of: MediaItem?.self) { group in
            var activeTasks = 0
            for name in filesToProcess {
                let fullPath = (directory as NSString).appendingPathComponent(name)
                if activeTasks >= maxConcurrentTasks {
                    if let item = await group.next() {
                        if let item { addItem(item) }
                    }
                    activeTasks -= 1
                }
                group.addTask {
                    return await Self.analyzeFile(
                        path: fullPath,
                        name: name,
                        parentID: parentID
                    )
                }
                activeTasks += 1
            }
            while let item = await group.next() {
                if let item { addItem(item) }
            }
        }
    }

    private static func analyzeFile(path: String, name: String, parentID: String) async -> MediaItem? {
        let fm = FileManager.default
        guard let mime = Self.matchMIME(name) else { return nil }
        let attributes = try? fm.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? UInt64
        var videoCodec: VideoCodec?
        var audioCodec: AudioCodec?
        var duration: Double?
        var width: Int?
        var height: Int?
        if mime.hasPrefix("video") || mime.hasPrefix("audio") {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            do {
                if let dur = try? await asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(dur)
                    if seconds.isFinite && seconds > 0 {
                        duration = seconds
                    }
                }
                let tracks = try await asset.load(.tracks)
                if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                    if let size = try? await videoTrack.load(.naturalSize) {
                        width = Int(size.width)
                        height = Int(size.height)
                    }
                    if let descriptions = try? await videoTrack.load(.formatDescriptions),
                        let desc = descriptions.first
                    {
                        let codecType = CMFormatDescriptionGetMediaSubType(desc)
                        videoCodec = VideoCodec(codecType: codecType)
                    }
                }
                if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                    if let descriptions = try? await audioTrack.load(.formatDescriptions),
                        let desc = descriptions.first
                    {
                        let codecType = CMFormatDescriptionGetMediaSubType(desc)
                        audioCodec = AudioCodec(codecType: codecType)
                    }
                }
            } catch {
                print("Failed to probe asset at \(path): \(error)")
            }
        }
        return MediaItem(
            id: path,
            parentID: parentID,
            title: name,
            isContainer: false,
            mimeType: mime,
            filePath: path,
            size: size,
            duration: duration,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            width: width,
            height: height
        )
    }

    private static func matchMIME(_ filename: String) -> String? {
        let ext: String = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "aac", "m4a": return "audio/mp4"
        default: return nil
        }
    }
}
