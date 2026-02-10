import Foundation

public struct Subscription: Sendable {
    public let sid: String
    public let callbackURL: String
    public let timeout: TimeInterval
    public let createdAt: Date
}
