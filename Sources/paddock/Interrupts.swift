import Dispatch
import Darwin

/// Runs `action` on the main actor when the process gets `number`, by default the SIGINT of
/// Ctrl-C, instead of being killed. Keep the returned source alive for as long as the handler
/// should stay installed.
@MainActor
func onInterrupt(_ number: Int32 = SIGINT, _ action: @escaping @MainActor () -> Void) -> any DispatchSourceSignal {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { action() }
    }
    source.resume()
    return source
}
