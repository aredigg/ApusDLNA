import AVFoundation

public enum VideoCodec: Sendable, Equatable {
    case h264
    case hevc
    case av01
    case other(FourCharCode)

    public var needsTranscode: Bool {
        switch self {
        case .av01: return true
        case .h264, .hevc: return false
        case .other: return true
        }
    }

    public init(codecType: FourCharCode) {
        print(MediaServer.intToASCII(codecType))
        switch codecType {
        case kCMVideoCodecType_H264:
            self = .h264
        case kCMVideoCodecType_HEVC:
            self = .hevc
        case kCMVideoCodecType_AV1:
            self = .av01
        default:
            self = .other(codecType)
        }
    }

}
