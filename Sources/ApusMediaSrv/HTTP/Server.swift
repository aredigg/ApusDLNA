import Foundation
import Network

public actor Server {
    public typealias Handler = @Sendable (Request) async -> Response

    private let port: NWEndpoint.Port
    private let handler: Handler
    private var listener: NWListener?
    private var buffers: [ObjectIdentifier: Data] = [:]
    private let queue: DispatchQueue = DispatchQueue(label: "com.jackalworks.apus-media.server")

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = NWEndpoint.Port(integerLiteral: port)
        self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }
        let listener: NWListener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self: Server else { return }
            connection.start(queue: self.queue)
            //Task { await self.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Server listening on port \(listener.port ?? 0)")
            case .failed(let error):
                print("Server listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        buffers.removeAll()
    }

    private func accept(_ connection: NWConnection) async {
        var complete: Bool = false
        do {
            while !complete {
                let (data, isComplete) = try await readOnce(from: connection)
                if let data: Data, !data.isEmpty {
                    if let response: Response = await processData(data, from: connection) {
                        let isHead: Bool =
                            await parseMethod(for: connection)?.uppercased() == "HEAD"
                        await send(response: response, isHead: isHead, on: connection)
                        return
                    }
                }
                complete = isComplete
            }
        } catch {

        }
        close(connection)
    }

    private func readOnce(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation({ continuation in
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 65535
            ) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        })
    }

    private func processData(_ data: Data, from connection: NWConnection) async -> Response? {
        let id: ObjectIdentifier = ObjectIdentifier(connection)
        var buffer: Data = buffers[id] ?? Data()
        buffer.append(data)
        buffers[id] = buffer
        guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else { return nil }
        let remote: NWEndpoint? = connection.currentPath?.remoteEndpoint
        guard let request: Request = parse(data: buffer, remoteEndpoint: remote) else {
            buffers[id] = nil
            return .badRequest
        }
        buffers[id] = nil
        return await handler(request)
    }

    private func parseMethod(for connection: NWConnection) -> String? {
        let id: ObjectIdentifier = ObjectIdentifier(connection)
        guard let buffer: Data = buffers[id],
            let str: String = String(data: buffer, encoding: .utf8),
            let firstLine: String = str.components(separatedBy: "\r\n").first
        else { return nil }
        return firstLine.split(separator: " ").first.map(String.init)
    }

    private func parse(data: Data, remoteEndpoint: NWEndpoint?) -> Request? {
        guard let str: String = String(data: data, encoding: .utf8) else { return nil }
        guard let sep: Range<String.Index> = str.range(of: "\r\n\r\n") else { return nil }
        let headerPart: String = String(str[..<sep.lowerBound])
        let bodyPart: Data = Data(str[sep.upperBound...].utf8)
        let lines: [String] = headerPart.components(separatedBy: "\r\n")
        guard let requestLine: String = lines.first else { return nil }
        let parts: [String.SubSequence] = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line: String in lines.dropFirst() {
            let keyValue: [String.SubSequence] = line.split(separator: ":", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            headers[String(keyValue[0]).lowercased()] = keyValue[1].trimmingCharacters(in: .whitespaces)
        }
        return Request(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: bodyPart.isEmpty ? nil : bodyPart,
            remoteEndpoint: remoteEndpoint
        )
    }

    private func send(response: Response, isHead: Bool, on connection: NWConnection) async {
        let headerData: Data = serializeHeaders(for: response)
        await writeBytes(headerData, to: connection)
        if !isHead {
            switch response.body {
            case .empty:
                break
            case .data(let data):
                await writeBytes(data, to: connection)
            case .stream(let stream):
                for await chunk: Data in stream {
                    await writeBytes(chunk, to: connection)
                }
            }
        }
        close(connection)
    }

    private func writeBytes(_ data: Data, to connection: NWConnection) async {
        await withCheckedContinuation({ (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed({ _ in continuation.resume() }))
        })

    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        buffers.removeValue(forKey: ObjectIdentifier(connection))

    }

    private func serializeHeaders(for response: Response) -> Data {
        var lines: [String] = [String]()
        lines.append("HTTP/1.1 \(response.statusCode) \(response.reason)")
        lines.append("Date: \(Date().formatted(.http))")
        lines.append("Connection: close")
        switch response.body {
        case .empty:
            lines.append("Content-Length: 0")
        case .data(let data):
            if response.headers["content-length"] == nil {
                lines.append("Content-Length: \(data.count)")
            }
        case .stream:
            if response.headers["transfer-encoding"] == nil {
                lines.append("Transfer-Encoding: chunked")
            }
        }
        for (key, value) in response.headers {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
