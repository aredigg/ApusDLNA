import Foundation

public enum Body: Sendable {
    case empty
    case data(Data)
    case stream(AsyncStream<Data>)
}

public struct Response: Sendable {
    public var statusCode: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Body

    public init(code: Int, reason: String, headers: [String: String] = [:], body: Body = .empty) {
        self.statusCode = code
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func ok(_ str: String, contentType: String = "text/plain") -> Response {
        let data: Data = Data(str.utf8)
        return Response(
            code: 200,
            reason: "OK",
            headers: [
                "Content-Type": contentType,
                "Content-Length": "\(data.count)",
            ],
            body: .data(data)
        )
    }

    public static func xml(_ str: String) -> Response {
        .ok(str, contentType: "text/xml; charset=\"utf-8\"")
    }

    public static let notFound: Response = Response(code: 404, reason: "Not Found")
    public static let badRequest: Response = Response(code: 400, reason: "Bad Request")
    public static let internalError: Response = Response(code: 500, reason: "Server Error")

}
