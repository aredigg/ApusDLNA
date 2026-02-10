public enum ObjectResponse {
    public static func envelope(
        action: String,
        serviceType: String,
        arguments: [(name: String, value: String)]
    ) -> String {
        var body: String = ""
        for arg in arguments {
            body += "<\(arg.name)>\(arg.value)</\(arg.name)>"
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
              s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:\(action)Response xmlns:u="\(serviceType)">
                  \(body)
                </u:\(action)Response>
              </s:Body>
            </s:Envelope>
            """
    }
}
