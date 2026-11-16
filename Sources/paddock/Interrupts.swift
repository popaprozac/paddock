import Dispatch
import Darwin

/// Runs `action` on the main actor when the user presses Ctrl-C, instead of killing the process.
/// Keep the returned source alive for as long as the handler should stay installed.
@MainActor
func onInterrupt(_ action: @escaping @MainActor () -> Void) -> any DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { action() }
    }
    source.resume()
    return source
}
