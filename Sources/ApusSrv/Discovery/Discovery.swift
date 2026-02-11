import Foundation
import Network

public actor Discovery {
    private var connectionGroup: NWConnectionGroup?
    private let host: NWEndpoint.Host = "239.255.255.250"
    private let port: NWEndpoint.Port = 1900
    private let queue: DispatchQueue = DispatchQueue(label: "com.jackalworks.apus-media.discovery")
    private var continuations: [UUID: AsyncStream<DiscoveryEvent>.Continuation] = [:]

    public init() {}

    public func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let id: UUID = UUID()
            continuations[id] = continuation

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }

    private func yield(_ event: DiscoveryEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func start() throws {
        guard connectionGroup == nil else { return }
        let endpoint: NWEndpoint = .hostPort(host: host, port: port)
        let multicastGroup: NWMulticastGroup = try NWMulticastGroup(for: [endpoint])
        let parameters: NWParameters = .udp
        parameters.allowLocalEndpointReuse = true
        let group: NWConnectionGroup = NWConnectionGroup(with: multicastGroup, using: parameters)
        group.setReceiveHandler(maximumMessageSize: 65_507, rejectOversizedMessages: true) {
            [weak self] (message, content, isComplete) in
            guard let self, isComplete, let content else { return }
            Task { await self.handleMessage(content, from: message) }
        }
        group.start(queue: queue)
        connectionGroup = group
    }

    public func stop() {
        connectionGroup?.cancel()
        connectionGroup = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    public func alive(usn: String, location: String, server: String, nt: String) {
        let message: String = """
            NOTIFY * HTTP/1.1\r
            HOST: \(host):\(port)\r
            CACHE-CONTROL: max-age=1800\r
            LOCATION: \(location)\r
            NT: \(nt)\r
            NTS: ssdp:alive\r
            SERVER: \(server)\r
            USN: \(usn)\r
            \r
            """
        send(message: message)
    }

    public func byebye(usn: String, nt: String) {
        let message: String = """
            NOTIFY * HTTP/1.1\r
            HOST: \(host):\(port)\r
            NT: \(nt)\r
            NTS: ssdp:byebye\r
            USN: \(usn)\r
            \r
            """
        send(message: message)
    }

    public func sendResponse(to endpoint: NWEndpoint, usn: String, location: String, server: String, st: String) {
        let response = """
            HTTP/1.1 200 OK\r
            CACHE-CONTROL: max-age=1800\r
            DATE: \(Date().formatted(.http))\r
            EXT:\r
            LOCATION: \(location)\r
            SERVER: \(server)\r
            ST: \(st)\r
            USN: \(usn)\r
            \r
            """
        let connection: NWConnection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: queue)
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed({ _ in connection.cancel() })
        )
    }

    private func handleMessage(_ data: Data, from message: NWConnectionGroup.Message) {
        guard let str: String = String(data: data, encoding: .utf8) else { return }
        guard str.uppercased().hasPrefix("M-SEARCH") else { return }
        let lines: [String] = str.components(separatedBy: "\r\n")
        var st: String?
        for line: String in lines {
            let parts: [String] =
                line
                .split(separator: ":", maxSplits: 1)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
            if parts.count == 2, parts[0].uppercased() == "ST" {
                st = parts[1]
                break
            }
        }
        guard let target: String = st, let endpoint: NWEndpoint = message.remoteEndpoint else { return }
        yield(.searchReceived(st: target, from: endpoint))
    }

    private func send(message: String) {
        guard let data: Data = message.data(using: .utf8) else { return }
        connectionGroup?.send(content: data) { error in
            if let error { print("Discovery send: \(error)") }
        }
    }

}
