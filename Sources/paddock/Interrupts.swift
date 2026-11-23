import Dispatch
import Darwin

/// Runs `action` on the main actor when the process gets `number`, by default the SIGINT of
/// Ctrl-C, instead of being killed. Keep the returned source alive for as long as the handler
/// should stay installed; cancelling it gives the signal back what it did before.
@MainActor
func onInterrupt(_ number: Int32 = SIGINT, _ action: @escaping @MainActor () -> Void) -> any DispatchSourceSignal {
    let previous = signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { action() }
    }
    source.setCancelHandler { signal(number, previous) }
    source.resume()
    return source
}
