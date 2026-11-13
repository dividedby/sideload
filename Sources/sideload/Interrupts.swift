import Darwin
import Dispatch
import SideloadCore
import Synchronization

/// Handles SIGINT/SIGTERM/SIGHUP with `DispatchSource`s. The default dispositions are ignored so the
/// sources see the signals; `PosixSpawnRunner` resets them in children so they still react normally.
func installInterruptHandlers(_ interrupt: Interrupt) -> [any DispatchSourceSignal] {
    let queue = DispatchQueue(label: "sideload.interrupt")
    return [SIGINT, SIGTERM, SIGHUP].map { signo in
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
        source.setEventHandler {
            // A command that already changed things (`provision --renew` moved cached profiles) reports it. Reading the
            // report seals its progress, so a move that main starts afterwards is refused; bounded, so a stuck lock can
            // never hold the exit.
            let context = Mutex<[String: JSONValue]>([:])
            _ = Interrupt.bounded(timeout: .milliseconds(500)) {
                if let report = cliInterruptReport.current() { context.withLock { $0 = report } }
            }
            // `inspect` unpacks an untrusted IPA into a scratch folder that must not outlive the process: the interrupt
            // gate removes it once the child groups are dead and before the object is written.
            let code = interrupt.handle(
                signal: signo, context: context.withLock { $0 },
                cleanup: { ScratchRegistry.shared.removeAllAndClose() })
            // _exit, not exit: stdio flush and atexit handlers could block after an abandoned write.
            if let code { _exit(code) } else { park() }
        }
        source.resume()
        return source
    }
}
