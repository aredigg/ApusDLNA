import Foundation

public actor MediaServer {
    private let device: DeviceDescription
    private let discovery: Discovery
    private let content: ScanDirectory
    private let subscriptions: SubscriptionManager
    private let transcoder: Transcoder
    private var server: Server?

    private let port: UInt16
    private var discoveryTask: Task<Void, Never>?
    private var localAddress: String = "0.0.0.0"

    public init(friendlyName: String = "Media Server", port: UInt16 = 8080) {
        self.port = port
        let uuid: String = UUID().uuidString
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
        //        self.server = Server(port: port) { _ in .notFound }
    }

    public func start(path: String) async throws {
        guard let ip: String = Interface.localIPv4Address() else { return }
        self.localAddress = ip
        try await content.scan(directory: path)
        let mediaServer: MediaServer = self
        let server: Server = Server(port: port) { request in
            await mediaServer.route(request)
        }
        try await server.start()
        try await discovery.start()
        let events: AsyncStream<DiscoveryEvent> = await discovery.events()
        discoveryTask = Task {
            for await event in events {
                await mediaServer.handleDiscoveryEvent(event)
            }
        }
        await alive()
        print("ApusDLNA started: \(device.friendlyName)")
    }

    public func stop() async {
        await bye()
        discoveryTask?.cancel()
        discoveryTask = nil
        await discovery.stop()
        await server?.stop()
        server = nil
        print("ApusDLNA stopped")
    }

    private func route(_ request: Request) async -> Response {
        switch (request.method.uppercased(), request.path) {
        case (_, "/description.xml"):
            return .xml(device.xml(baseURL: baseURL()))
        case ("POST", "/ContentDirectory/control"):
            return await handleControl(request)
        case ("SUBSCRIBE", "/ContentDirectory/event"):
            return await handleSubscribe(request)
        case ("UNSUBSCRIBE", "/ContentDirectory/event"):
            return await handleUnsubscribe(request)
        case (_, let path) where path.hasPrefix("/m/"):
            return await handleMedia(request)
        default:
            return .notFound
        }
    }

    private func handleControl(_ request: Request) async -> Response {
        guard
            let header: String = request.header("soapaction"),
            let object: ObjectRequest = ObjectRequest.parse(action: header, body: request.body)
        else {
            return .badRequest
        }
        switch object.actionName {
        case "Browse":
            return await handleBrowse(object)
        case "GetSearchCapabilities":
            return .xml(
                ObjectResponse.envelope(
                    action: "GetSearchCapabilities",
                    serviceType: object.serviceType,
                    arguments: [("SearchCaps", "")]
                )
            )
        case "GetSortCapabilities":
            return .xml(
                ObjectResponse.envelope(
                    action: "GetSortCapabilities",
                    serviceType: object.serviceType,
                    arguments: [("SortCaps", "")]
                )
            )
        case "GetSystemUpdateID":
            return .xml(
                ObjectResponse.envelope(
                    action: "GetSystemUpdateID",
                    serviceType: object.serviceType,
                    arguments: [("Id", "1")]
                )
            )
        default:
            return .badRequest
        }
    }

    private func handleBrowse(_ object: ObjectRequest) async -> Response {
        let objectID: String = object.arguments["ObjectID"] ?? "Root"
        let flag: String = object.arguments["BrowseFlag"] ?? "BrowseDirectChildren"
        let start: Int = Int(object.arguments["StartingIndex"] ?? "Root") ?? 0
        let count: Int = Int(object.arguments["RequestedCount"] ?? "Root") ?? 0

        let (items, total) = await content.browse(
            objectID: objectID,
            flag: flag,
            startIndex: start,
            requestedCount: count
        )
        let metadata: String = buildMetadata(items: items)
        return .xml(
            ObjectResponse.envelope(
                action: "Browse",
                serviceType: object.serviceType,
                arguments: [
                    ("Result", escapeXML(metadata)),
                    ("NumberReturned", "\(items.count)"),
                    ("TotalMatches", "\(total)"),
                    ("UpdateID", "1"),
                ]
            )
        )
    }

    private func handleMedia(_ request: Request) async -> Response {
        let path: String = String(request.path.dropFirst("/m/".count))
        guard
            let decoded: String = path.removingPercentEncoding,
            let item: MediaItem = await content.item(for: decoded),
            let filePath: String = item.filePath
        else {
            return .notFound
        }
        guard FileManager.default.fileExists(atPath: filePath) else { return .notFound }
        // TODO we need to check codec of video stream
        if item.needsTranscode {
            let stream = await transcoder.transcode(
                path: filePath,
                codec: .av01
            )
            return Response(
                code: 200,
                reason: "OK",
                headers: [
                    "Content-Type": "video/mp4",
                    "Transfer-Encoding": "chunked",
                    "transferMode.dlna.org": "Streaming",
                ],
                body: .stream(stream)
            )
        }
        return await serveFile(
            path: filePath,
            mimeType: item.mimeType ?? "application/octet-stream",
            request: request
        )
    }

    private func serveFile(path: String, mimeType: String, request: Request) async -> Response {
        guard let handle: FileHandle = FileHandle(forReadingAtPath: path) else {
            return .notFound
        }
        defer { try? handle.close() }
        let fileSize: UInt64 = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)
        if let rangeHeader = request.header("range"),
            let range = parseRange(rangeHeader, fileSize: fileSize)
        {
            handle.seek(toFileOffset: range.start)
            let length = range.end - range.start + 1
            let data = handle.readData(ofLength: Int(length))

            return Response(
                code: 206,
                reason: "Partial Content",
                headers: [
                    "Content-Type": mimeType,
                    "Content-Length": "\(length)",
                    "Content-Range": "bytes \(range.start)-\(range.end)/\(fileSize)",
                    "Accept-Ranges": "bytes",
                ],
                body: .data(data)
            )
        }

        let stream: AsyncStream<Data> = AsyncStream<Data> { continuation in
            Task.detached {
                guard let streamHandle: FileHandle = FileHandle(forReadingAtPath: path) else {
                    continuation.finish()
                    return
                }
                defer { try? streamHandle.close() }
                var empty: Bool = false
                while !empty {
                    let chunk: Data = streamHandle.readData(ofLength: 256 * 1024)
                    continuation.yield(chunk)
                    empty = chunk.isEmpty
                }
                continuation.finish()
            }
        }

        return Response(
            code: 200,
            reason: "OK",
            headers: [
                "Content-Type": mimeType,
                "Content-Length": "\(fileSize)",
                "Accept-Ranges": "bytes",
            ],
            body: .stream(stream)
        )
    }

    private func parseRange(_ header: String, fileSize: UInt64) -> (start: UInt64, end: UInt64)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec: String.SubSequence = header.dropFirst("bytes=".count)
        let parts: [String.SubSequence] = spec.split(separator: "-")
        guard let startStr: String.SubSequence = parts.first,
            let start: UInt64 = UInt64(startStr)
        else { return nil }
        let end: UInt64
        if parts.count > 1, let e: UInt64 = UInt64(parts[1]) {
            end = min(e, fileSize - 1)
        } else {
            end = fileSize - 1
        }
        guard start <= end else { return nil }
        return (start, end)
    }

    private func handleSubscribe(_ request: Request) async -> Response {
        guard let callback: String = request.header("callback") else { return .badRequest }
        let url: String =
            callback
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
        let subscription: Subscription = await subscriptions.subscribe(callbackURL: url)
        return Response(
            code: 200,
            reason: "OK",
            headers: [
                "SID": subscription.sid,
                "TIMEOUT": "Second-\(Int(subscription.timeout))",
            ]
        )
    }

    private func handleUnsubscribe(_ request: Request) async -> Response {
        guard let sid = request.header("sid") else { return .badRequest }
        await subscriptions.unsubscribe(sid: sid)
        return Response(code: 200, reason: "OK")
    }

    private func handleDiscoveryEvent(_ event: DiscoveryEvent) async {
        switch event {
        case .searchReceived(let st, let from):
            let targets: [String] = [
                "ssdp:all",
                "upnp:rootdevice",
                "urn:schemas-upnp-org:device:MediaServer:1",
                "urn:schemas-upnp-org:service:ContentDirectory:1",
                "urn:schemas-upnp-org:service:ConnectionManager:1",
                "uuid:\(device.uuid)",
            ]
            guard targets.contains(st) else { return }
            await discovery.sendResponse(
                to: from,
                usn: "uuid:\(device.uuid)",
                location: "\(baseURL())/description.xml",
                server: device.serverHeader,
                st: st
            )
        }
    }

    private func alive() async {
        await discovery.alive(
            usn: "uuid:\(device.uuid)",
            location: "\(baseURL())/description.xml",
            server: device.serverHeader,
            nt: "upnp:rootdevice"
        )
    }

    private func bye() async {
        await discovery.byebye(
            usn: "uuid:\(device.uuid)",
            nt: "upnp:rootdevice"
        )
    }

    private func baseURL() -> String {
        "http://\(localAddress):\(port)"
    }

    private func buildMetadata(items: [MediaItem]) -> String {
        var xml: String = """
            <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
            """
        for item: MediaItem in items {
            if item.isContainer {
                xml += """
                    <container id="\(escapeXMLAttr(item.id))" \
                    parentID="\(escapeXMLAttr(item.parentID))" restricted="1">
                      <dc:title>\(escapeXML(item.title))</dc:title>
                      <upnp:class>object.container</upnp:class>
                    </container>
                    """
            } else {
                let res: String
                if let mime = item.mimeType, let path = item.filePath {
                    let encoded: String =
                        path.addingPercentEncoding(
                            withAllowedCharacters: .urlPathAllowed
                        ) ?? path
                    let url: String = "\(baseURL())/media/\(encoded)"
                    let sizeAttr: String = item.size.map { " size=\"\($0)\"" } ?? ""
                    res = """
                        <res protocolInfo="http-get:*:\(mime):*"\(sizeAttr)>\
                        \(escapeXML(url))</res>
                        """
                } else {
                    res = ""
                }
                let upnpClass: String
                if let mime: String = item.mimeType {
                    if mime.hasPrefix("video") {
                        upnpClass = "object.item.videoItem"
                    } else if mime.hasPrefix("audio") {
                        upnpClass = "object.item.audioItem.musicTrack"
                    } else if mime.hasPrefix("image") {
                        upnpClass = "object.item.imageItem"
                    } else {
                        upnpClass = "object.item"
                    }
                } else {
                    upnpClass = "object.item"
                }
                xml += """
                    <item id="\(escapeXMLAttr(item.id))" \
                    parentID="\(escapeXMLAttr(item.parentID))" restricted="1">
                      <dc:title>\(escapeXML(item.title))</dc:title>
                      <upnp:class>\(upnpClass)</upnp:class>
                      \(res)
                    </item>
                    """
            }
        }
        xml += "</DIDL-Lite>"
        return xml
    }

    private func escapeXML(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeXMLAttr(_ str: String) -> String {
        escapeXML(str)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
