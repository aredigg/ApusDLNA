import Foundation

public struct ObjectRequest: Sendable {
    public let serviceType: String
    public let actionName: String
    public let arguments: [String: String]
    public static func parse(
        action header: String,
        body: Data?
    ) -> ObjectRequest? {
        let cleaned: String =
            header
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")

        let parts: [String.SubSequence] = cleaned.split(separator: "#")
        guard parts.count == 2 else { return nil }

        let serviceType: String = String(parts[0])
        let actionName: String = String(parts[1])

        var arguments: [String: String] = [:]

        if let body: Data, let xml: String = String(data: body, encoding: .utf8) {
            let lines: [String] = xml.components(separatedBy: CharacterSet.newlines)
            for line: String in lines {
                let trimmed: String = line.trimmingCharacters(in: .whitespaces)
                if let open: Range<String.Index> = trimmed.range(of: "<"),
                    let close: Range<String.Index> = trimmed.range(of: ">"),
                    !trimmed.hasPrefix("</"),
                    !trimmed.hasPrefix("<?")
                {
                    let tag: String =
                        String(trimmed[open.upperBound..<close.lowerBound])
                        .split(separator: " ").first.map(String.init) ?? ""
                    if !tag.isEmpty, !tag.hasPrefix("/"),
                        let endTag: Range<String.Index> = trimmed.range(of: "</\(tag)>")
                    {
                        let value: String = String(trimmed[close.upperBound..<endTag.lowerBound])
                        arguments[tag] = value
                    }
                }
            }
        }

        return ObjectRequest(
            serviceType: serviceType,
            actionName: actionName,
            arguments: arguments
        )
    }
}
