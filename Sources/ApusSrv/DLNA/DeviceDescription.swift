public struct DeviceDescription: Sendable {
    public let uuid: String
    public let friendlyName: String
    public let manufacturer: String
    public let modelName: String
    public let serverHeader: String

    public init(uuid: String, friendlyName: String, manufacturer: String, modelName: String) {
        self.uuid = uuid
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.serverHeader = "\(modelName)/1.0 UPnP/2.0 DLNADOC/1.51"
    }

    public func xml(baseURL: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
            <friendlyName>\(friendlyName)</friendlyName>
            <manufacturer>\(manufacturer)</manufacturer>
            <modelName>\(modelName)</modelName>
            <UDN>uuid:\(uuid)</UDN>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
                <controlURL>/ContentDirectory/control</controlURL>
                <eventSubURL>/ContentDirectory/event</eventSubURL>
                <SCPDURL>/ContentDirectory/scpd.xml</SCPDURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                <controlURL>/ConnectionManager/control</controlURL>
                <eventSubURL>/ConnectionManager/event</eventSubURL>
                <SCPDURL>/ConnectionManager/scpd.xml</SCPDURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
    }
}
