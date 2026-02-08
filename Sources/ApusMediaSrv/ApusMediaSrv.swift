// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import Network

public class MediaServer: DiscoveryDelegate {
    private let port: UInt16 = 8080
    private let discovery: Discovery = Discovery()
    private let server: Server

    public init() async {
        server = Server(port: port)
        await discovery.setDelegate(self)
    }

    public func discovery(service: Discovery, didReceive cp: String, from endpoint: NWEndpoint) {

    }
}
