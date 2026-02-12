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
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            Task { await self.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("Server listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        print("Server listening on port \(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        buffers.removeAll()
    }

    private func accept(_ connection: NWConnection) async {
        var keepAlive = true
        while keepAlive {
            if let (response, method) = await processData(Data(), from: connection) {
                keepAlive = await send(response: response, method: method, on: connection)
                continue
            }
            do {
                let (data, isComplete) = try await readOnce(from: connection)
                if isComplete {
                    keepAlive = false
                    break
                }
                guard let data, !data.isEmpty else { continue }
                if let (response, method) = await processData(data, from: connection) {
                    keepAlive = await send(response: response, method: method, on: connection)
                }
            } catch {
                print("Connection error: \(error)")
                keepAlive = false
            }
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

    private func processData(_ data: Data, from connection: NWConnection) async -> (Response, String)? {
        let id: ObjectIdentifier = ObjectIdentifier(connection)
        var buffer = buffers[id] ?? Data()
        if !data.isEmpty {
            buffer.append(data)
            buffers[id] = buffer
        }
        let separatorData: Data = Data("\r\n\r\n".utf8)
        guard let separatorRange = buffer.range(of: separatorData) else { return nil }
        let headerEndIndex: Int = separatorRange.upperBound
        let headerData: Data = buffer[..<headerEndIndex]
        guard let headerString = String(data: headerData, encoding: .utf8),
            let requestLine = headerString.components(separatedBy: "\r\n").first
        else {
            buffers[id] = nil
            return (.badRequest, "GET")
        }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else {
            buffers[id] = nil
            return (.badRequest, "GET")
        }
        let method = String(requestLineParts[0])
        let path = String(requestLineParts[1])
        var headers: [String: String] = [:]
        let headerLines = headerString.components(separatedBy: "\r\n").dropFirst()
        for line in headerLines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let totalBytesNeeded = headerEndIndex + max(contentLength, 0)
        guard buffer.count >= totalBytesNeeded else { return nil }
        let bodyData =
            contentLength > 0
            ? buffer[headerEndIndex..<headerEndIndex + contentLength]
            : nil
        let request = Request(
            method: method,
            path: path,
            headers: headers,
            body: bodyData,
            remoteEndpoint: connection.currentPath?.remoteEndpoint
        )
        let remaining = buffer.dropFirst(totalBytesNeeded)
        buffers[id] = remaining.isEmpty ? nil : remaining
        let response = await handler(request)
        return (response, method)
    }

    private func parseMethod(for connection: NWConnection) -> String? {
        let id: ObjectIdentifier = ObjectIdentifier(connection)
        guard let buffer: Data = buffers[id],
            let str: String = String(data: buffer, encoding: .utf8),
            let firstLine: String = str.components(separatedBy: "\r\n").first
        else { return nil }
        return firstLine.split(separator: " ").first.map(String.init)
    }

    private func send(response: Response, method: String, on connection: NWConnection) async -> Bool {
        let (headerData, shouldKeepAlive) = serializeHeaders(for: response)
        guard await writeBytes(headerData, to: connection) else { return false }
        let isHead = method.uppercased() == "HEAD"
        if !isHead {
            switch response.body {
            case .empty:
                break
            case .data(let data):
                guard await writeBytes(data, to: connection) else { return false }
            case .stream(let stream):
                let isChunked =
                    response.headers["transfer-encoding"]?
                    .lowercased().contains("chunked") ?? false
                for await chunk in stream {
                    if chunk.isEmpty { continue }
                    if isChunked {
                        let prefix = Data(String(format: "%X\r\n", chunk.count).utf8)
                        guard await writeBytes(prefix, to: connection) else { return false }
                        guard await writeBytes(chunk, to: connection) else { return false }
                        guard await writeBytes(Data("\r\n".utf8), to: connection) else { return false }
                    } else {
                        guard await writeBytes(chunk, to: connection) else { return false }
                    }
                }
                if isChunked {
                    guard await writeBytes(Data("0\r\n\r\n".utf8), to: connection) else { return false }
                }
            }
        }
        return shouldKeepAlive
    }

    private func writeBytes(_ data: Data, to connection: NWConnection) async -> Bool {
        guard !data.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        buffers.removeValue(forKey: ObjectIdentifier(connection))

    }

    private func serializeHeaders(for response: Response) -> (Data, Bool) {
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in response.headers { normalizedHeaders[key.lowercased()] = value }
        let connectionVal = normalizedHeaders["connection"]?.lowercased()
        let shouldKeepAlive = connectionVal != "close"
        if normalizedHeaders["connection"] == nil {
            normalizedHeaders["connection"] = "keep-alive"
        }
        switch response.body {
        case .empty:
            if normalizedHeaders["content-length"] == nil {
                normalizedHeaders["content-length"] = "0"
            }
        case .data(let data):
            if normalizedHeaders["content-length"] == nil {
                normalizedHeaders["content-length"] = "\(data.count)"
            }
        case .stream:
            if normalizedHeaders["transfer-encoding"] == nil
                && normalizedHeaders["content-length"] == nil
            {
                normalizedHeaders["transfer-encoding"] = "chunked"
            }
        }
        var lines = ["HTTP/1.1 \(response.statusCode) \(response.reason)"]
        lines.append("Date: \(Date().formatted(.http))")
        for (key, value) in normalizedHeaders {
            lines.append("\(key): \(value)")
        }
        lines.append("\r\n")
        return (Data(lines.joined(separator: "\r\n").utf8), shouldKeepAlive)
    }
}
