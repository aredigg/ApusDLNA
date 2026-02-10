import Foundation

public actor SubscriptionManager {
    private var subscriptions: [String: Subscription] = [:]

    public init() {}

    public func subscribe(
        callbackURL: String,
        timeout: TimeInterval = 1800
    ) -> Subscription {
        let sid: String = "uuid:\(UUID().uuidString)"
        let sub: Subscription = Subscription(
            sid: sid,
            callbackURL: callbackURL,
            timeout: timeout,
            createdAt: Date(),
            seq: 0
        )
        subscriptions[sid] = sub
        return sub
    }

    public func renew(sid: String, timeout: TimeInterval = 1800) -> Bool {
        guard var subscription: Subscription = subscriptions[sid] else { return false }
        subscription = Subscription(
            sid: subscription.sid,
            callbackURL: subscription.callbackURL,
            timeout: timeout,
            createdAt: Date(),
            seq: subscription.seq
        )
        subscriptions[sid] = subscription
        return true
    }

    public func unsubscribe(sid: String) {
        subscriptions.removeValue(forKey: sid)
    }

    public func activeSubscriptions() -> [Subscription] {
        let now: Date = Date()
        for (sid, subscription) in subscriptions {
            if now.timeIntervalSince(subscription.createdAt) > subscription.timeout {
                subscriptions.removeValue(forKey: sid)
            }
        }
        return Array(subscriptions.values)
    }

    public func notify(eventXML: String) async {
        let active: [Subscription] = activeSubscriptions()
        for subscription: Subscription in active {
            guard let url: URL = URL(string: subscription.callbackURL) else { continue }
            let next = subscription.seq &+ 1
            let sid = subscription.sid
            subscriptions[sid] = Subscription(
                sid: sid,
                callbackURL: subscription.callbackURL,
                timeout: subscription.timeout,
                createdAt: subscription.createdAt,
                seq: next
            )
            var request: URLRequest = URLRequest(url: url)
            request.httpMethod = "NOTIFY"
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.setValue("upnp:event", forHTTPHeaderField: "NT")
            request.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
            request.setValue(subscription.sid, forHTTPHeaderField: "SID")
            request.setValue("\(next)", forHTTPHeaderField: "SEQ")
            request.httpBody = Data(eventXML.utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
