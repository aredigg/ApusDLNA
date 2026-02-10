public struct Route: Sendable {
    public let method: String?
    public let path: String
    public let handler: @Sendable (Request) async -> Response

    public init(
        method: String? = nil,
        path: String,
        handler: @escaping @Sendable (Request) async -> Response
    ) {
        self.method = method
        self.path = path
        self.handler = handler
    }
}

public struct Router: Sendable {
    private let routes: [Route]

    public init(routes: [Route]) {
        self.routes = routes
    }

    public func route(_ request: Request) async -> Response {
        for route: Route in routes {
            if let method: String = route.method, method.uppercased() != request.method.uppercased() { continue }
            if validRoute(pattern: route.path, actual: request.path) {
                return await route.handler(request)
            }
        }
        return .notFound
    }

    private func validRoute(pattern: String, actual: String) -> Bool {
        if pattern.hasSuffix("/*") {
            let prefix: String = String(pattern.dropLast(2))
            return actual == prefix || actual.hasPrefix(prefix + "/")
        }
        return pattern == actual
    }

}
