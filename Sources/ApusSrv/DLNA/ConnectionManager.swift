public actor ConnectionManagerState {
    public struct Info: Sendable {
        public let id: Int
        public let rcsID: Int
        public let avTransportID: Int
        public let protocolInfo: String
        public let peerConnectionManager: String
        public let peerConnectionID: Int
        public let direction: String
        public let status: String
    }

    private var nextID: Int = 1
    private var connections: [Int: Info] = [:]

    public init() {}

    public func getCurrentConnectionIDsCSV() -> String {
        if connections.isEmpty { return "0" }
        return connections.keys.sorted().map(String.init).joined(separator: ",")
    }

    public func getInfo(id: Int) -> Info? {
        connections[id]
    }

    public func prepareForConnection(
        remoteProtocolInfo: String,
        peerConnectionManager: String,
        peerConnectionID: Int,
        direction: String
    ) -> Info {
        let id = nextID
        nextID += 1

        let info = Info(
            id: id,
            rcsID: -1,
            avTransportID: -1,
            protocolInfo: remoteProtocolInfo,
            peerConnectionManager: peerConnectionManager,
            peerConnectionID: peerConnectionID,
            direction: direction,
            status: "OK"
        )
        connections[id] = info
        return info
    }

    public func connectionComplete(id: Int) -> Bool {
        connections.removeValue(forKey: id) != nil
    }
}
