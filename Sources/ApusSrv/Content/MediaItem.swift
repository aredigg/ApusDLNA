public struct MediaItem: Sendable {
    public let id: String
    public let parentID: String
    public let title: String
    public let isContainer: Bool
    public let mimeType: String?
    public let filePath: String?
    public let size: UInt64?
    public let duration: String?

    public init(
        id: String,
        parentID: String,
        title: String,
        isContainer: Bool,
        mimeType: String? = nil,
        filePath: String? = nil,
        size: UInt64? = nil,
        duration: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.isContainer = isContainer
        self.mimeType = mimeType
        self.filePath = filePath
        self.size = size
        self.duration = duration
    }
}
