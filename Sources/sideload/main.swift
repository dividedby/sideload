import Darwin
import SideloadCore

// pipe()/open() hand out the lowest free fd; keep 0-2 occupied so none of them can be reused for a pipe.
for fd: Int32 in 0...2 where fcntl(fd, F_GETFD) == -1 { _ = open("/dev/null", O_RDWR) }

// A closed stdout reader (e.g. `sideload | head`) must not kill the process.
signal(SIGPIPE, SIG_IGN)

let interrupt = Interrupt()
let interruptSources = installInterruptHandlers(interrupt)
#if DEBUG
writeTestReadyMarker()
#endif

/// A signal won the race for stdout and the exit. Falling off the end of main.swift would `exit(0)`.
func park() -> Never {
    while true { pause() }
}

let argv = Array(CommandLine.arguments.dropFirst())
#if DEBUG
let hooked = await runTestSleepChild()
let envelope = if let hooked { hooked } else { await run(argv: argv) }
#else
let envelope = await run(argv: argv)
#endif
switch interrupt.finishMain(envelope) {
case .exit(let code):
    // Only a fully written object lets `provision` forget the moves it reported: a closed pipe, a failed write or a
    // signal leaves the ledger record, and the next run reports it.
    if interrupt.delivered { await cliPostEmit.runIfPending() }
    exit(code)
case .writeFailed(let error):
    // Writing the one object failed; stdout is unusable, so report on stderr. Signals park from here on,
    // so a stderr write that blocks (full pipe) must not hold the process: bound it, then _exit (exit
    // could block on the stdio lock the abandoned write holds). No O_NONBLOCK: fd 2 may be shared.
    _ = Interrupt.bounded(timeout: .seconds(1)) { fputs("sideload: failed to write output: \(error)\n", stderr) }
    _exit(70)
case .yield:
    park()
}
