public struct MediaItem: Sendable {
    public let id: String
    public let parentID: String
    public let title: String
    public let isContainer: Bool
    public let mimeType: String?
    public let filePath: String?
    public let size: UInt64?
    public let duration: Double?
    public let videoCodec: VideoCodec?
    public let audioCodec: AudioCodec?
    public let width: Int?
    public let height: Int?
    public var needsTranscode: Bool { videoCodec?.needsTranscode ?? false }

    public init(
        id: String,
        parentID: String,
        title: String,
        isContainer: Bool,
        mimeType: String? = nil,
        filePath: String? = nil,
        size: UInt64? = nil,
        duration: Double? = nil,
        videoCodec: VideoCodec? = nil,
        audioCodec: AudioCodec? = nil,
        width: Int? = nil,
        height: Int? = nil,
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.isContainer = isContainer
        self.mimeType = mimeType
        self.filePath = filePath
        self.size = size
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
    }
}
