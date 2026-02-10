import Foundation

public actor ScanDirectory {
    private var items: [String: MediaItem] = [:]
    private var children: [String: [String]] = [:]

    public init() {
        let root: MediaItem = MediaItem(
            id: "Root",
            parentID: "None",
            title: "Root",
            isContainer: true
        )
        items["Root"] = root
        children["Root"] = []
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
        let childIDs: [String] = children[objectID] ?? []
        let total: Int = childIDs.count
        let count: Int = requestedCount == 0 ? total : requestedCount
        let slice: [MediaItem] =
            childIDs
            .dropFirst(startIndex)
            .prefix(count)
            .compactMap { items[$0] }
        return (slice, total)
    }

    public func item(for id: String) -> MediaItem? {
        items[id]
    }

    public func scan(directory: String, parentID: String = "Root") async throws {
        let fm: FileManager = FileManager.default
        let contents: [String] = try fm.contentsOfDirectory(atPath: directory)
        for name: String in contents.sorted() {
            let fullPath: String = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let id: String = fullPath
            if isDir.boolValue {
                let folder: MediaItem = MediaItem(
                    id: id,
                    parentID: parentID,
                    title: name,
                    isContainer: true
                )
                addItem(folder)
                try await scan(directory: fullPath, parentID: id)
            } else {
                guard let mime: String = Self.matchMIME(name) else { continue }
                let attributes: [FileAttributeKey: Any] = try fm.attributesOfItem(atPath: fullPath)
                let size: UInt64? = attributes[.size] as? UInt64
                var videoCodec: VideoCodec?
                var audioCodec: AudioCodec?
                var duration: Double?
                var width: Int?
                var height: Int?
                if mime.hasPrefix("video") {
                    videoCodec = await FindCodec.videoCodec(atPath: fullPath)
                    audioCodec = await FindCodec.audioCodec(atPath: fullPath)
                    duration = await FindCodec.duration(atPath: fullPath)
                    let dimensions = await FindCodec.videoDimensions(atPath: fullPath)
                    width = dimensions?.0
                    height = dimensions?.1

                }
                let item: MediaItem = MediaItem(
                    id: id,
                    parentID: parentID,
                    title: name,
                    isContainer: false,
                    mimeType: mime,
                    filePath: fullPath,
                    size: size,
                    duration: duration,
                    videoCodec: videoCodec,
                    audioCodec: audioCodec,
                    width: width,
                    height: height,
                )
                addItem(item)
            }
        }
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
