import Network

public enum DiscoveryEvent: Sendable {
    case searchReceived(st: String, from: NWEndpoint)
}
