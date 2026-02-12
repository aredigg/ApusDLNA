import Foundation

public actor MediaServer {
    private let device: DeviceDescription
    private let discovery: Discovery
    private let content: ScanDirectory
    private let subscriptions: SubscriptionManager
    private let transcoder: Transcoder
    private var server: Server?

    private let connectionManagerState = ConnectionManagerState()
    private var aliveTask: Task<Void, Never>?

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
    }

    public func start(path: String) async throws {
        guard let ip: String = Interface.localIPv4Address() else { return }
        self.localAddress = ip
        try await content.scan(directory: path)
        let mediaServer: MediaServer = self
        let startServer: Server = Server(port: port) { request in
            await mediaServer.route(request)
        }
        try await startServer.start()
        try await discovery.start()
        let events: AsyncStream<DiscoveryEvent> = await discovery.events()
        discoveryTask = Task {
            for await event in events {
                await mediaServer.handleDiscoveryEvent(event)
            }
        }
        for _ in 0..<3 {
            await alive()
            try? await Task.sleep(for: .milliseconds(200))
        }
        aliveTask?.cancel()
        aliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                if Task.isCancelled { break }
                await self.alive()
            }
        }
        print("ApusDLNA started: \(device.friendlyName)")
        self.server = startServer
    }

    public func stop() async {
        aliveTask?.cancel()
        aliveTask = nil
        for _ in 0..<3 {
            await bye()
            try? await Task.sleep(for: .milliseconds(200))
        }
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
        case (_, "/ContentDirectory/scpd.xml"):
            return .xml(directorySCPDXML())
        case ("POST", "/ContentDirectory/control"):
            return await handleDirectoryControl(request)
        case ("SUBSCRIBE", "/ContentDirectory/event"):
            return await handleSubscribe(request)
        case ("UNSUBSCRIBE", "/ContentDirectory/event"):
            return await handleUnsubscribe(request)
        case (_, "/ConnectionManager/scpd.xml"):
            return .xml(connectionManagerSCPDXML())
        case ("POST", "/ConnectionManager/control"):
            return await handleConnectionManagerControl(request)
        case ("SUBSCRIBE", "/ConnectionManager/event"):
            return await handleSubscribe(request)
        case ("UNSUBSCRIBE", "/ConnectionManager/event"):
            return await handleUnsubscribe(request)
        case (_, let path) where path.hasPrefix("/m/"):
            return await handleMedia(request)
        default:
            return .notFound
        }
    }

    private func handleDirectoryControl(_ request: Request) async -> Response {
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
        let objectID: String = object.arguments["ObjectID"] ?? "0"
        let flag: String = object.arguments["BrowseFlag"] ?? "BrowseDirectChildren"
        let start: Int = Int(object.arguments["StartingIndex"] ?? "0") ?? 0
        let count: Int = Int(object.arguments["RequestedCount"] ?? "0") ?? 0

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
        let token: String = String(request.path.dropFirst("/m/".count))

        let paddedToken: String = {
            let base64: String =
                token
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let paddingCount: Int = (4 - (base64.count % 4)) % 4
            return base64 + String(repeating: "=", count: paddingCount)
        }()

        guard
            let decoded: Data = Data(base64Encoded: paddedToken),
            let itemID: String = String(data: decoded, encoding: .utf8),
            let item: MediaItem = await content.item(for: itemID),
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
                    "content-type": "video/mp4",
                    "transfer-encoding": "chunked",
                    "transfermode.dlna.org": "Streaming",
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSize = attributes[.size] as? UInt64
        else {
            return .notFound
        }
        var startOffset: UInt64 = 0
        var length: UInt64 = fileSize
        var statusCode = 200
        var reason = "OK"
        var contentRange: String? = nil
        if let rangeHeader = request.header("range"),
            let range = parseRange(rangeHeader, fileSize: fileSize)
        {
            startOffset = range.start
            length = range.end - range.start + 1
            statusCode = 206
            reason = "Partial Content"
            contentRange = "bytes \(range.start)-\(range.end)/\(fileSize)"
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
        var remaining: UInt64 = length
        Task.detached {
            guard let fileHandle = FileHandle(forReadingAtPath: path) else {
                continuation.finish()
                return
            }
            defer { try? fileHandle.close() }
            try? fileHandle.seek(toOffset: startOffset)
            let bufferSize = 256 * 1024
            while remaining > 0 {
                if Task.isCancelled { break }
                let chunkSize = min(remaining, UInt64(bufferSize))
                let chunk = fileHandle.readData(ofLength: Int(chunkSize))
                if chunk.isEmpty { break }
                let result = continuation.yield(chunk)
                switch result {
                case .terminated, .dropped:
                    return
                case .enqueued:
                    break
                @unknown default:
                    break
                }
                remaining -= UInt64(chunk.count)
                try? await Task.sleep(for: .microseconds(100))
            }
            continuation.finish()
        }
        var headers: [String: String] = [
            "content-type": mimeType,
            "content-length": "\(length)",
            "accept-ranges": "bytes",
        ]
        if let contentRange { headers["content-range"] = contentRange }
        return Response(
            code: statusCode,
            reason: reason,
            headers: headers,
            body: .stream(stream)
        )
    }

    private func parseRange(_ header: String, fileSize: UInt64) -> (start: UInt64, end: UInt64)? {
        guard fileSize > 0 else { return nil }
        guard header.trimmingCharacters(in: .whitespaces).hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let specs = spec.split(separator: ",", omittingEmptySubsequences: true)
        guard specs.count == 1 else { return nil }
        let rangeSpec = specs[0].trimmingCharacters(in: .whitespaces)

        let bounds: [String.SubSequence] = rangeSpec.split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if !bounds[0].isEmpty {
            guard let start: UInt64 = UInt64(bounds[0]) else { return nil }
            let end: UInt64
            if bounds[1].isEmpty {
                end = fileSize - 1
            } else {
                guard let requestedEnd: UInt64 = UInt64(bounds[1]) else { return nil }
                end = min(requestedEnd, fileSize - 1)
            }
            guard start <= end else { return nil }
            return (start, end)
        }
        guard !bounds[1].isEmpty, let suffixLength: UInt64 = UInt64(bounds[1]) else { return nil }
        if suffixLength == 0 { return nil }
        let length: UInt64 = min(suffixLength, fileSize)
        let start: UInt64 = fileSize - length
        let end: UInt64 = fileSize - 1
        return (start, end)
    }

    private func handleSubscribe(_ request: Request) async -> Response {
        if let sid = request.header("sid") {
            let renewed = await subscriptions.renew(sid: sid)
            guard renewed else { return .preconditionFailed }
            return Response(
                code: 200,
                reason: "OK",
                headers: [
                    "sid": sid,
                    "timeout": "second-1800",
                ]
            )
        }
        guard let callback: String = request.header("callback") else { return .badRequest }
        let url: String =
            callback
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
        let subscription: Subscription = await subscriptions.subscribe(callbackURL: url)
        if request.path.hasPrefix("/ConnectionManager/") {
            await notifyConnectionManagerEvent()
        } else if request.path.hasPrefix("/ContentDirectory/") {
            await notifyContentDirectoryEvent()
        }
        return Response(
            code: 200,
            reason: "OK",
            headers: [
                "sid": subscription.sid,
                "timeout": "second-\(Int(subscription.timeout))",
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
            let baseUSN: String = "uuid:\(device.uuid)"
            let usn: String = {
                if st.lowercased().hasPrefix("uuid:") { return baseUSN }
                return "\(baseUSN)::\(st)"
            }()
            await discovery.sendResponse(
                to: from,
                usn: usn,
                location: "\(baseURL())/description.xml",
                server: device.serverHeader,
                st: st
            )
        }
    }

    private func alive() async {
        let location: String = "\(baseURL())/description.xml"
        let server: String = device.serverHeader
        let baseUSN: String = "uuid:\(device.uuid)"

        let announcements: [(nt: String, usn: String)] = [
            ("upnp:rootdevice", "\(baseUSN)::upnp:rootdevice"),
            ("uuid:\(device.uuid)", baseUSN),
            ("urn:schemas-upnp-org:device:MediaServer:1", "\(baseUSN)::urn:schemas-upnp-org:device:MediaServer:1"),
            (
                "urn:schemas-upnp-org:service:ContentDirectory:1",
                "\(baseUSN)::urn:schemas-upnp-org:service:ContentDirectory:1"
            ),
            (
                "urn:schemas-upnp-org:service:ConnectionManager:1",
                "\(baseUSN)::urn:schemas-upnp-org:service:ConnectionManager:1"
            ),
        ]

        for announcement in announcements {
            await discovery.alive(
                usn: announcement.usn,
                location: location,
                server: server,
                nt: announcement.nt
            )
        }
    }

    private func bye() async {
        let baseUSN: String = "uuid:\(device.uuid)"

        let announcements: [(nt: String, usn: String)] = [
            ("upnp:rootdevice", "\(baseUSN)::upnp:rootdevice"),
            ("uuid:\(device.uuid)", baseUSN),
            ("urn:schemas-upnp-org:device:MediaServer:1", "\(baseUSN)::urn:schemas-upnp-org:device:MediaServer:1"),
            (
                "urn:schemas-upnp-org:service:ContentDirectory:1",
                "\(baseUSN)::urn:schemas-upnp-org:service:ContentDirectory:1"
            ),
            (
                "urn:schemas-upnp-org:service:ConnectionManager:1",
                "\(baseUSN)::urn:schemas-upnp-org:service:ConnectionManager:1"
            ),
        ]

        for announcement in announcements {
            await discovery.byebye(usn: announcement.usn, nt: announcement.nt)
        }
    }

    private func baseURL() -> String {
        "http://\(localAddress):\(port)"
    }

    private func mediaURL(for itemID: String) -> String {
        let data: Data = Data(itemID.utf8)
        let base64: String = data.base64EncodedString()
        let base64url: String =
            base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(baseURL())/m/\(base64url)"
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
                if let mime = item.mimeType {
                    let url: String = mediaURL(for: item.id)
                    let durationAttr: String
                    if let duration = item.duration {
                        let durationStr = Duration.seconds(duration).formatted(
                            .time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 3)))
                        durationAttr = " duration=\"\(durationStr)\""
                    } else {
                        durationAttr = ""
                    }
                    let resolutionAttr: String = {
                        if let w = item.width, let h = item.height {
                            return " resolution=\"\(w)x\(h)\""
                        }
                        return ""
                    }()
                    let sizeAttr: String = item.size.map { " size=\"\($0)\"" } ?? ""
                    let dlnaFlags = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
                    res = """
                        <res protocolInfo="http-get:*:\(mime):\(dlnaFlags)"\(sizeAttr)\(durationAttr)\(resolutionAttr)>\(escapeXML(url))</res>
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

    private func directorySCPDXML() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion>
            <major>1</major>
            <minor>0</minor>
          </specVersion>

          <actionList>
            <action>
              <name>Browse</name>
              <argumentList>
                <argument>
                  <name>ObjectID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable>
                </argument>
                <argument>
                  <name>BrowseFlag</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable>
                </argument>
                <argument>
                  <name>Filter</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable>
                </argument>
                <argument>
                  <name>StartingIndex</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable>
                </argument>
                <argument>
                  <name>RequestedCount</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable>
                </argument>
                <argument>
                  <name>SortCriteria</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable>
                </argument>

                <argument>
                  <name>Result</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable>
                </argument>
                <argument>
                  <name>NumberReturned</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable>
                </argument>
                <argument>
                  <name>TotalMatches</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable>
                </argument>
                <argument>
                  <name>UpdateID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetSearchCapabilities</name>
              <argumentList>
                <argument>
                  <name>SearchCaps</name>
                  <direction>out</direction>
                  <relatedStateVariable>SearchCapabilities</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetSortCapabilities</name>
              <argumentList>
                <argument>
                  <name>SortCaps</name>
                  <direction>out</direction>
                  <relatedStateVariable>SortCapabilities</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetSystemUpdateID</name>
              <argumentList>
                <argument>
                  <name>Id</name>
                  <direction>out</direction>
                  <relatedStateVariable>SystemUpdateID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>Search</name>
              <argumentList>
                <argument>
                  <name>ContainerID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable>
                </argument>
                <argument>
                  <name>SearchCriteria</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_SearchCriteria</relatedStateVariable>
                </argument>
                <argument>
                  <name>Filter</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable>
                </argument>
                <argument>
                  <name>StartingIndex</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable>
                </argument>
                <argument>
                  <name>RequestedCount</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable>
                </argument>
                <argument>
                  <name>SortCriteria</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable>
                </argument>

                <argument>
                  <name>Result</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable>
                </argument>
                <argument>
                  <name>NumberReturned</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable>
                </argument>
                <argument>
                  <name>TotalMatches</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable>
                </argument>
                <argument>
                  <name>UpdateID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_UpdateID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>CreateObject</name>
              <argumentList>
                <argument>
                  <name>ContainerID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable>
                </argument>
                <argument>
                  <name>Elements</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable>
                </argument>

                <argument>
                  <name>ObjectID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable>
                </argument>
                <argument>
                  <name>Result</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>DestroyObject</name>
              <argumentList>
                <argument>
                  <name>ObjectID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>UpdateObject</name>
              <argumentList>
                <argument>
                  <name>ObjectID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable>
                </argument>
                <argument>
                  <name>CurrentTagValue</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_TagValueList</relatedStateVariable>
                </argument>
                <argument>
                  <name>NewTagValue</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_TagValueList</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>ImportResource</name>
              <argumentList>
                <argument>
                  <name>SourceURI</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_URI</relatedStateVariable>
                </argument>
                <argument>
                  <name>DestinationURI</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_URI</relatedStateVariable>
                </argument>

                <argument>
                  <name>TransferID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_TransferID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetTransferProgress</name>
              <argumentList>
                <argument>
                  <name>TransferID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_TransferID</relatedStateVariable>
                </argument>

                <argument>
                  <name>TransferStatus</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_TransferStatus</relatedStateVariable>
                </argument>
                <argument>
                  <name>TransferLength</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_TransferLength</relatedStateVariable>
                </argument>
                <argument>
                  <name>TransferTotal</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_TransferTotal</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>DeleteResource</name>
              <argumentList>
                <argument>
                  <name>ResourceURI</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_URI</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>StopTransferResource</name>
              <argumentList>
                <argument>
                  <name>TransferID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_TransferID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetFreeStorageSpace</name>
              <argumentList>
                <argument>
                  <name>StorageID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_StorageID</relatedStateVariable>
                </argument>

                <argument>
                  <name>FreeBytes</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_FreeBytes</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetTotalStorageSpace</name>
              <argumentList>
                <argument>
                  <name>StorageID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_StorageID</relatedStateVariable>
                </argument>

                <argument>
                  <name>TotalBytes</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_TotalBytes</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetDeviceCapabilities</name>
              <argumentList>
                <argument>
                  <name>PlayMedia</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_PlayMedia</relatedStateVariable>
                </argument>
                <argument>
                  <name>RecMedia</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_RecMedia</relatedStateVariable>
                </argument>
                <argument>
                  <name>RecQualityModes</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_RecQualityModes</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>X_GetFeatureList</name>
              <argumentList>
                <argument>
                  <name>FeatureList</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable>
                </argument>
              </argumentList>
            </action>
          </actionList>

          <serviceStateTable>
            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_ObjectID</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_Result</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_BrowseFlag</name>
              <dataType>string</dataType>
              <allowedValueList>
                <allowedValue>BrowseMetadata</allowedValue>
                <allowedValue>BrowseDirectChildren</allowedValue>
              </allowedValueList>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_Filter</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_Index</name>
              <dataType>ui4</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_Count</name>
              <dataType>ui4</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_SortCriteria</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>SortCapabilities</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>SearchCapabilities</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="yes">
              <name>SystemUpdateID</name>
              <dataType>ui4</dataType>
            </stateVariable>

            <stateVariable sendEvents="yes">
              <name>ContainerUpdateIDs</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_SearchCriteria</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_TagValueList</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_URI</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_TransferID</name>
              <dataType>ui4</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_TransferStatus</name>
              <dataType>string</dataType>
              <allowedValueList>
                <allowedValue>COMPLETED</allowedValue>
                <allowedValue>ERROR</allowedValue>
                <allowedValue>IN_PROGRESS</allowedValue>
                <allowedValue>STOPPED</allowedValue>
              </allowedValueList>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_TransferLength</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_TransferTotal</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_StorageID</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_FreeBytes</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_PlayMedia</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_RecMedia</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_RecQualityModes</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_TotalBytes</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_UpdateID</name>
              <dataType>ui4</dataType>
            </stateVariable>
          </serviceStateTable>
        </scpd>
        """
    }

    private func connectionManagerSCPDXML() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">
          <specVersion>
            <major>1</major>
            <minor>0</minor>
          </specVersion>

          <actionList>
            <action>
              <name>GetProtocolInfo</name>
              <argumentList>
                <argument>
                  <name>Source</name>
                  <direction>out</direction>
                  <relatedStateVariable>SourceProtocolInfo</relatedStateVariable>
                </argument>
                <argument>
                  <name>Sink</name>
                  <direction>out</direction>
                  <relatedStateVariable>SinkProtocolInfo</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>PrepareForConnection</name>
              <argumentList>
                <argument>
                  <name>RemoteProtocolInfo</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable>
                </argument>
                <argument>
                  <name>PeerConnectionManager</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable>
                </argument>
                <argument>
                  <name>PeerConnectionID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable>
                </argument>
                <argument>
                  <name>Direction</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable>
                </argument>

                <argument>
                  <name>ConnectionID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable>
                </argument>
                <argument>
                  <name>AVTransportID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable>
                </argument>
                <argument>
                  <name>RcsID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>ConnectionComplete</name>
              <argumentList>
                <argument>
                  <name>ConnectionID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetCurrentConnectionIDs</name>
              <argumentList>
                <argument>
                  <name>ConnectionIDs</name>
                  <direction>out</direction>
                  <relatedStateVariable>CurrentConnectionIDs</relatedStateVariable>
                </argument>
              </argumentList>
            </action>

            <action>
              <name>GetCurrentConnectionInfo</name>
              <argumentList>
                <argument>
                  <name>ConnectionID</name>
                  <direction>in</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable>
                </argument>

                <argument>
                  <name>RcsID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable>
                </argument>
                <argument>
                  <name>AVTransportID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable>
                </argument>
                <argument>
                  <name>ProtocolInfo</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable>
                </argument>
                <argument>
                  <name>PeerConnectionManager</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable>
                </argument>
                <argument>
                  <name>PeerConnectionID</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable>
                </argument>
                <argument>
                  <name>Direction</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable>
                </argument>
                <argument>
                  <name>Status</name>
                  <direction>out</direction>
                  <relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable>
                </argument>
              </argumentList>
            </action>
          </actionList>

          <serviceStateTable>
            <stateVariable sendEvents="yes">
              <name>SourceProtocolInfo</name>
              <dataType>string</dataType>
            </stateVariable>
            <stateVariable sendEvents="yes">
              <name>SinkProtocolInfo</name>
              <dataType>string</dataType>
            </stateVariable>
            <stateVariable sendEvents="yes">
              <name>CurrentConnectionIDs</name>
              <dataType>string</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_ProtocolInfo</name>
              <dataType>string</dataType>
            </stateVariable>
            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_ConnectionManager</name>
              <dataType>string</dataType>
            </stateVariable>
            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_ConnectionID</name>
              <dataType>i4</dataType>
            </stateVariable>
            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_AVTransportID</name>
              <dataType>i4</dataType>
            </stateVariable>
            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_RcsID</name>
              <dataType>i4</dataType>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_Direction</name>
              <dataType>string</dataType>
              <allowedValueList>
                <allowedValue>Input</allowedValue>
                <allowedValue>Output</allowedValue>
              </allowedValueList>
            </stateVariable>

            <stateVariable sendEvents="no">
              <name>A_ARG_TYPE_ConnectionStatus</name>
              <dataType>string</dataType>
              <allowedValueList>
                <allowedValue>OK</allowedValue>
                <allowedValue>ContentFormatMismatch</allowedValue>
                <allowedValue>InsufficientBandwidth</allowedValue>
                <allowedValue>UnreliableChannel</allowedValue>
                <allowedValue>Unknown</allowedValue>
              </allowedValueList>
            </stateVariable>
          </serviceStateTable>
        </scpd>
        """
    }

    private func notifyConnectionManagerEvent() async {
        let ids = await connectionManagerState.getCurrentConnectionIDsCSV()
        let source = dlnaSourceProtocolInfoCSV()
        let sink = ""

        let eventXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
              <e:property><SourceProtocolInfo>\(escapeXML(source))</SourceProtocolInfo></e:property>
              <e:property><SinkProtocolInfo>\(escapeXML(sink))</SinkProtocolInfo></e:property>
              <e:property><CurrentConnectionIDs>\(escapeXML(ids))</CurrentConnectionIDs></e:property>
            </e:propertyset>
            """

        await subscriptions.notify(eventXML: eventXML)
    }

    private func notifyContentDirectoryEvent() async {
        let systemUpdateID: UInt32 = 1
        let containerUpdateIDs: String = ""
        let eventXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
              <e:property>
                <SystemUpdateID>\(systemUpdateID)</SystemUpdateID>
              </e:property>
              <e:property>
                <ContainerUpdateIDs>\(escapeXML(containerUpdateIDs))</ContainerUpdateIDs>
              </e:property>
            </e:propertyset>
            """
        await subscriptions.notify(eventXML: eventXML)
    }

    private func handleConnectionManagerControl(_ request: Request) async -> Response {
        guard
            let header: String = request.header("soapaction"),
            let object: ObjectRequest = ObjectRequest.parse(action: header, body: request.body)
        else {
            return upnpFault(statusCode: 500, code: 402, description: "Invalid Args")
        }

        // Ensure caller is actually addressing ConnectionManager.
        // Many clients send the correct serviceType; enforce it.
        if object.serviceType != "urn:schemas-upnp-org:service:ConnectionManager:1" {
            return upnpFault(statusCode: 500, code: 401, description: "Invalid Action")
        }

        switch object.actionName {
        case "GetProtocolInfo":
            let source = dlnaSourceProtocolInfoCSV()
            let sink = ""  // DMS is usually not a sink
            let body = ObjectResponse.envelope(
                action: "GetProtocolInfo",
                serviceType: object.serviceType,
                arguments: [("Source", source), ("Sink", sink)]
            )
            return .xml(body)

        case "GetCurrentConnectionIDs":
            let ids = await connectionManagerState.getCurrentConnectionIDsCSV()
            let body = ObjectResponse.envelope(
                action: "GetCurrentConnectionIDs",
                serviceType: object.serviceType,
                arguments: [("ConnectionIDs", ids)]
            )
            return .xml(body)

        case "GetCurrentConnectionInfo":
            guard let idStr = object.arguments["ConnectionID"], let id = Int(idStr) else {
                return upnpFault(statusCode: 500, code: 402, description: "Invalid Args")
            }

            if id == 0 {
                // Per common practice: 0 is “no connection”.
                let body = ObjectResponse.envelope(
                    action: "GetCurrentConnectionInfo",
                    serviceType: object.serviceType,
                    arguments: [
                        ("RcsID", "-1"),
                        ("AVTransportID", "-1"),
                        ("ProtocolInfo", ""),
                        ("PeerConnectionManager", ""),
                        ("PeerConnectionID", "-1"),
                        ("Direction", "Output"),
                        ("Status", "OK"),
                    ]
                )
                return .xml(body)
            }

            guard let info = await connectionManagerState.getInfo(id: id) else {
                return upnpFault(statusCode: 500, code: 706, description: "Invalid Connection Reference")
            }

            let body = ObjectResponse.envelope(
                action: "GetCurrentConnectionInfo",
                serviceType: object.serviceType,
                arguments: [
                    ("RcsID", "\(info.rcsID)"),
                    ("AVTransportID", "\(info.avTransportID)"),
                    ("ProtocolInfo", escapeXML(info.protocolInfo)),
                    ("PeerConnectionManager", escapeXML(info.peerConnectionManager)),
                    ("PeerConnectionID", "\(info.peerConnectionID)"),
                    ("Direction", info.direction),
                    ("Status", info.status),
                ]
            )
            return .xml(body)

        case "PrepareForConnection":
            guard
                let remoteProtocolInfo = object.arguments["RemoteProtocolInfo"],
                let peerCM = object.arguments["PeerConnectionManager"],
                let peerIDStr = object.arguments["PeerConnectionID"],
                let peerID = Int(peerIDStr),
                let direction = object.arguments["Direction"]
            else {
                return upnpFault(statusCode: 500, code: 402, description: "Invalid Args")
            }

            let info = await connectionManagerState.prepareForConnection(
                remoteProtocolInfo: remoteProtocolInfo,
                peerConnectionManager: peerCM,
                peerConnectionID: peerID,
                direction: direction
            )

            // Event: CurrentConnectionIDs changes
            await notifyConnectionManagerEvent()

            let body = ObjectResponse.envelope(
                action: "PrepareForConnection",
                serviceType: object.serviceType,
                arguments: [
                    ("ConnectionID", "\(info.id)"),
                    ("AVTransportID", "\(info.avTransportID)"),
                    ("RcsID", "\(info.rcsID)"),
                ]
            )
            return .xml(body)

        case "ConnectionComplete":
            guard let idStr = object.arguments["ConnectionID"], let id = Int(idStr) else {
                return upnpFault(statusCode: 500, code: 402, description: "Invalid Args")
            }
            _ = await connectionManagerState.connectionComplete(id: id)
            await notifyConnectionManagerEvent()

            let body = ObjectResponse.envelope(
                action: "ConnectionComplete",
                serviceType: object.serviceType,
                arguments: []
            )
            return .xml(body)

        default:
            return upnpFault(statusCode: 500, code: 401, description: "Invalid Action")
        }
    }

    private func dlnaSourceProtocolInfoCSV() -> String {
        // DLNA additionalInfo is the 4th field of protocolInfo.
        // Keep this conservative:
        // - OP=01 => byte-range supported
        // - CI=0  => not transcoded (this is a capability list, not per-item)
        // - FLAGS => common superset used by many DMS implementations
        let commonAdditionalInfo =
            "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

        // MP4-only (plus images) per your constraint.
        // Avoid advertising strict DLNA.ORG_PN for video/mp4 because your audio varies
        // (AAC vs AC-3/E-AC-3/Atmos), and incorrect PN causes some renderers to reject.
        let entries: [String] = [
            "http-get:*:video/mp4:\(commonAdditionalInfo)",
            "http-get:*:audio/mp4:\(commonAdditionalInfo)",
            "http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG;\(commonAdditionalInfo)",
            "http-get:*:image/png:\(commonAdditionalInfo)",  // not a classic DLNA PN, but many accept
        ]

        return entries.joined(separator: ",")
    }

    private func upnpFault(statusCode: Int, code: Int, description: String) -> Response {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
              s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <s:Fault>
                  <faultcode>s:Client</faultcode>
                  <faultstring>UPnPError</faultstring>
                  <detail>
                    <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
                      <errorCode>\(code)</errorCode>
                      <errorDescription>\(escapeXML(description))</errorDescription>
                    </UPnPError>
                  </detail>
                </s:Fault>
              </s:Body>
            </s:Envelope>
            """
        return .upnpErr(xml)
    }

    private func escapeXML(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count)
        for c in str {
            switch c {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(c)
            }
        }
        return result
    }

    private func escapeXMLAttr(_ str: String) -> String {
        escapeXML(str)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func intToASCII(_ n: FourCharCode) -> String {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: n).bigEndian) { bytes in
            String(decoding: bytes, as: UTF8.self)
        }
    }

}
