import Foundation

public enum Interface {
    public static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface: ifaddrs = ptr.pointee
            let family: sa_family_t = iface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let flags: Int32 = Int32(iface.ifa_flags)
            guard flags & IFF_UP != 0,
                flags & IFF_RUNNING != 0,
                flags & IFF_LOOPBACK == 0
            else { continue }
            let name: String = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var addr: sockaddr = iface.ifa_addr.pointee
            var hostname: [CChar] = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result: Int32 = getnameinfo(
                &addr,
                socklen_t(iface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            guard let ip: String = String(utf8String: hostname) else { continue }
            guard !ip.hasPrefix("169.254.") else { continue }
            return ip
        }
        return nil
    }
}
