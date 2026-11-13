import SideloadCore

/// What a running command wants in the `INTERRUPTED` object (`provision --renew`); the signal handlers read it.
let cliInterruptReport = InterruptReport()

/// Work to run once the one stdout object was fully written (`provision`'s ledger settlement); `main.swift` runs it.
let cliPostEmit = PostEmit()

/// The live `Services` plus the CLI's interrupt report and post-emit work.
func liveServices() -> Services {
    var services = Services.live()
    services.interruptReport = cliInterruptReport
    services.postEmit = cliPostEmit
    return services
}
