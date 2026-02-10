import Foundation

public actor MediaServer {
    private let device: DeviceDescription
    private let discovery: Discovery
    private let server: Server
    private let content: ScanDirectory
    private let subscriptions: SubscriptionManager
    private let transcoder: Transcoder

    private let port: UInt16
    private var discoveryTask: Task<Void, Never>?

    public init(friendlyName: String = "Apus Media Server", port: UInt16 = 8080, path: String) {
        self.port = port
        let uuid = UUID().uuidString
        self.device = DeviceDescription(
            uuid: uuid,
            friendlyName: friendlyName,
            manufacturer: "Jackalworks",
            modelName: "ApusDLNA"
        )
        self.discovery = Discovery()
        self.content = ScanDirectory()
        self.subscriptions = SubscriptionManager()
        self.transcoder = Transcoder()
        self.server = Server(port: port) { _ in .notFound }
    }
}
