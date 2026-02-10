import AVFoundation

public enum AudioCodec: Sendable, Equatable {
    case aac
    case ac3
    case other(FourCharCode)

    public init(codecType: FourCharCode) {
        print(codecType)
        switch codecType {
        default:
            self = .other(codecType)
        }
    }
}
