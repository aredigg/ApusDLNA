import ApusSrv
import Foundation

struct ApusDLNAMain {
    static func main() async throws {
        let mediaServer: MediaServer = MediaServer(friendlyName: "Media Server")
        try await mediaServer.start(path: ".")
        await waitForTerminationSignal()
        await mediaServer.stop()
    }
}

try await ApusDLNAMain.main()

private func waitForTerminationSignal() async {
    await withCheckedContinuation { continuation in
        let signals: [Int32] = [SIGINT, SIGTERM]
        class SourceSignals { var sources: [DispatchSourceSignal] = [] }
        let sourceSignals = SourceSignals()
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                print("\nReceived signal \(sig), shutting down...")
                for src in sourceSignals.sources { src.cancel() }
                continuation.resume()
            }
            source.resume()
            sourceSignals.sources.append(source)
        }
    }
}
