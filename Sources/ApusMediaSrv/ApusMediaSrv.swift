// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import Network

public class MediaServer: DiscoveryDelegate {
    private let discovery: Discovery = Discovery()

    public init() {}

    public func discovery(service: Discovery, didReceive cp: String, from endpoint: NWEndpoint) {

    }
}
