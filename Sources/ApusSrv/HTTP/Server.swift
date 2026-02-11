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
            guard let self else { return }
            connection.start(queue: self.queue)
            Task { await self.accept(connection) }
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
                        let isHead: Bool = parseMethod(for: connection)?.uppercased() == "HEAD"
                        await send(response: response, isHead: isHead, on: connection)
                        return
                    }
                }
                complete = isComplete
            }
        } catch {
            print("accept error")
        }
        close(connection)
    }

    private func readOnce(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation({ continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) {
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
        let connectionID: ObjectIdentifier = ObjectIdentifier(connection)
        var buffer: Data = buffers[connectionID] ?? Data()
        buffer.append(data)
        buffers[connectionID] = buffer

        let separatorData: Data = Data("\r\n\r\n".utf8)
        guard let separatorRange: Range<Data.Index> = buffer.range(of: separatorData) else {
            return nil
        }

        let headerEndIndex: Int = separatorRange.upperBound
        let headerData: Data = buffer[..<headerEndIndex]

        guard let headerString: String = String(data: headerData, encoding: .utf8) else {
            buffers[connectionID] = nil
            return .badRequest
        }

        let headerLines: [String] = headerString.components(separatedBy: "\r\n")
        guard let requestLine: String = headerLines.first else {
            buffers[connectionID] = nil
            return .badRequest
        }

        let requestLineParts: [Substring] = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else {
            buffers[connectionID] = nil
            return .badRequest
        }

        var headers: [String: String] = [:]
        headers.reserveCapacity(headerLines.count)

        for line: String in headerLines.dropFirst() {
            let keyValue: [Substring] = line.split(separator: ":", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            let key: String = String(keyValue[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let value: String = String(keyValue[1]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength: Int = Int(headers["content-length"] ?? "") ?? 0
        let totalBytesNeeded: Int = headerEndIndex + max(contentLength, 0)

        guard buffer.count >= totalBytesNeeded else {
            return nil
        }

        let bodyData: Data? =
            contentLength > 0
            ? buffer[headerEndIndex..<headerEndIndex + contentLength]
            : nil

        let remoteEndpoint: NWEndpoint? = connection.currentPath?.remoteEndpoint
        let request: Request = Request(
            method: String(requestLineParts[0]),
            path: String(requestLineParts[1]),
            headers: headers,
            body: bodyData,
            remoteEndpoint: remoteEndpoint
        )
        let remaining: Data = buffer.dropFirst(totalBytesNeeded)
        buffers[connectionID] = remaining.isEmpty ? nil : remaining
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

    private func send(response: Response, isHead: Bool, on connection: NWConnection) async {
        let headerData: Data = serializeHeaders(for: response)
        await writeBytes(headerData, to: connection)
        guard !isHead else {
            close(connection)
            return
        }
        switch response.body {
        case .empty:
            break
        case .data(let data):
            await writeBytes(data, to: connection)
        case .stream(let stream):
            for await chunk in stream where !chunk.isEmpty {
                let prefix = Data(String(format: "%X\r\n", chunk.count).utf8)
                await writeBytes(prefix, to: connection)
                await writeBytes(chunk, to: connection)
                await writeBytes(Data("\r\n".utf8), to: connection)
            }
            await writeBytes(Data("0\r\n\r\n".utf8), to: connection)
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
        var headers: [String: String] = [:]
        headers.reserveCapacity(response.headers.count)
        for (key, value) in response.headers {
            headers[key.lowercased()] = value
        }
        var lines: [String] = [String]()
        lines.append("HTTP/1.1 \(response.statusCode) \(response.reason)")
        lines.append("Date: \(Date().formatted(.http))")
        lines.append("Connection: close")

        switch response.body {
        case .empty:
            if headers["content-length"] == nil {
                headers["content-length"] = "0"
            }
        case .data(let data):
            if headers["content-length"] == nil {
                headers["content-length"] = "\(data.count)"
            }
        case .stream:
            if headers["transfer-encoding"] == nil {
                headers["transfer-encoding"] = "chunked"
            }
        }
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
