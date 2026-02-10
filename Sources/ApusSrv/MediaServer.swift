import Foundation

public actor MediaServer {
    private let device: DeviceDescription
    private let discovery: Discovery
    private let content: ScanDirectory
    private let subscriptions: SubscriptionManager
    private let transcoder: Transcoder
    private var server: Server?

    private let connectionManagerState = ConnectionManagerState()

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
        await alive()
        print("ApusDLNA started: \(device.friendlyName)")
        self.server = startServer
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
        if request.path.hasPrefix("/ConnectionManager/") {
            await notifyConnectionManagerEvent()
        } else if request.path.hasPrefix("/ContentDirectory/") {
            await notifyContentDirectoryEvent()
        }
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
                    let url: String = "\(baseURL())/m/\(encoded)"
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
