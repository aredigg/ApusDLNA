import AVFoundation

public enum AudioCodec: Sendable, Equatable {
    case aac
    case ac3
    case other(FourCharCode)

    public init(codecType: FourCharCode) {
        print(MediaServer.intToASCII(codecType))
        switch codecType {
        case 0x6161_6320:
            self = .aac
        default:
            self = .other(codecType)
        }
    }
}
