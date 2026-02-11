import Foundation

public struct ObjectRequest: Sendable {
    public let serviceType: String
    public let actionName: String
    public let arguments: [String: String]

    public static func parse(action header: String, body: Data?) -> ObjectRequest? {
        let cleanedHeader: String =
            header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")

        let headerParts: [Substring] = cleanedHeader.split(separator: "#", maxSplits: 1)
        guard headerParts.count == 2 else { return nil }

        let serviceType: String = String(headerParts[0])
        let actionName: String = String(headerParts[1])

        guard let body, !body.isEmpty else {
            return ObjectRequest(serviceType: serviceType, actionName: actionName, arguments: [:])
        }

        let delegate = LeafTextCollector()
        let parser = XMLParser(data: body)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        guard parser.parse() else { return nil }

        return ObjectRequest(
            serviceType: serviceType,
            actionName: actionName,
            arguments: delegate.arguments
        )
    }
}

private final class LeafTextCollector: NSObject, XMLParserDelegate {
    private(set) var arguments: [String: String] = [:]

    private var depth: Int = 0
    private var insideBody: Bool = false
    private var bodyDepth: Int = 0

    private var elementStack: [String] = []
    private var currentText: String = ""
    private var hasChildElementStack: [Bool] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qualifiedElementName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1

        let qualified: String = qualifiedElementName ?? elementName
        let localName: String = qualified.split(separator: ":").last.map(String.init) ?? qualified

        if !insideBody, localName.caseInsensitiveCompare("Body") == .orderedSame {
            insideBody = true
            bodyDepth = depth
        }

        if insideBody, depth > bodyDepth {
            if !hasChildElementStack.isEmpty {
                hasChildElementStack[hasChildElementStack.count - 1] = true
            }
            elementStack.append(localName)
            hasChildElementStack.append(false)
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideBody, !elementStack.isEmpty else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qualifiedElementName: String?
    ) {
        let qualified: String = qualifiedElementName ?? elementName
        let localName: String = qualified.split(separator: ":").last.map(String.init) ?? qualified

        if insideBody, !elementStack.isEmpty, elementStack[elementStack.count - 1] == localName {
            let hadChildElement: Bool = hasChildElementStack.removeLast()
            _ = elementStack.removeLast()

            if !hadChildElement {
                let value: String = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    arguments[localName] = value
                }
            }

            currentText = ""
        }

        if insideBody, localName.caseInsensitiveCompare("Body") == .orderedSame, depth == bodyDepth {
            insideBody = false
            bodyDepth = 0
        }

        depth -= 1
    }
}
