import ApusSrv
import Foundation

struct ApusDLNAMain {
    static func main() async throws {
        let mediaServer: MediaServer = MediaServer(friendlyName: "Media Server")
        try await mediaServer.start(path: ".")
        signal(SIGINT, SIG_IGN)
        let sigint: any DispatchSourceSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.resume()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sigint.setEventHandler { continuation.resume() }
        }
        await mediaServer.stop()
    }
}
