import Foundation
import Network

public protocol DiscoveryDelegate: AnyObject {
    func discovery(service: Discovery, didReceive cp: String, from endpoint: NWEndpoint)

}

public actor Discovery {
    private var connectionGroup: NWConnectionGroup?
    private let host: NWEndpoint.Host = "239.255.255.250"
    private let port: NWEndpoint.Port = 1900
    private let queue: DispatchQueue = DispatchQueue(label: "com.jackalworks.discovery")

    public weak var delegate: (any DiscoveryDelegate)?

    public init() {}

    public func setDelegate(_ delegate: (any DiscoveryDelegate)?) {
        self.delegate = delegate
    }

    public func start() throws {
        guard connectionGroup == nil else { return }

        let endpoint: NWEndpoint = NWEndpoint.hostPort(host: host, port: port)
        let multicastGroup: NWMulticastGroup = try NWMulticastGroup(for: [endpoint])

        let parameters: NWParameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        let group: NWConnectionGroup = NWConnectionGroup(with: multicastGroup, using: parameters)

        group.setReceiveHandler(maximumMessageSize: 65_507, rejectOversizedMessages: true) {
            [weak self] (message, content, isComplete) in
            guard let self else { return }
            guard isComplete, let content else { return }
            Task { await self.handleMessage(content, from: message) }
        }

        group.start(queue: queue)
        connectionGroup = group
    }

    public func stop() {
        connectionGroup?.cancel()
        connectionGroup = nil
    }

    public func alive(usn: String, location: String, server: String, nt: String) {
        let message =
            "NOTIFY * HTTP/1.1\r\n" + "HOST: \(host):\(port)\r\n"
            + "CACHE-CONTROL: max-age=1800\r\n" + "LOCATION: \(location)\r\n" + "NT: \(nt)\r\n"
            + "NTS: ssdp:alive\r\n" + "SERVER: \(server)\r\n" + "USN: \(usn)\r\n" + "\r\n"
        send(message: message)
    }

    public func sendResponse(
        to endpoint: NWEndpoint, usn: String, location: String, server: String, st: String
    ) {
        let response =
            "HTTP/1.1 200 OK\r\n" + "CACHE-CONTROL: max-age=1800\r\n"
            + "DATE: \(Date().formatted(.http))\r\n" + "EXT:\r\n" + "LOCATION: \(location)\r\n"
            + "SERVER: \(server)\r\n" + "ST: \(st)\r\n" + "USN: \(usn)\r\n" + "\r\n"
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: queue)
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed({ _ in connection.cancel() }))
    }

    private func handleMessage(_ data: Data, from message: NWConnectionGroup.Message) async {
        guard let str = String(data: data, encoding: .utf8) else { return }
        guard str.uppercased().hasPrefix("M-SEARCH") else { return }

        let lines = str.components(separatedBy: "\r\n")
        var st: String?

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map({
                $0.trimmingCharacters(in: .whitespaces)
            })
            if parts.count == 2, parts[0].uppercased() == "ST" {
                st = parts[1]
                break
            }
        }

        guard let target = st else { return }
        guard let endpoint = message.remoteEndpoint else { return }

        let delegate = self.delegate
        delegate?.discovery(service: self, didReceive: target, from: endpoint)
    }

    private func send(message: String) {
        guard let data = message.data(using: .utf8) else { return }
        connectionGroup?.send(content: data) { error in
            if let error = error {
                print("Discovery send: \(error)")
            }
        }
    }

}
