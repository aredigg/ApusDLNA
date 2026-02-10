import Foundation
import Network

public struct Request: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?
    public let remoteEndpoint: NWEndpoint?

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static let empty = Request(
        method: "",
        path: "",
        headers: [:],
        body: nil,
        remoteEndpoint: nil
    )
}
