#if DEBUG
import Darwin
import SideloadCore

/// Debug builds only (compiled out of release): when `SIDELOAD_TEST_SLEEP_CHILD` names an executable, run it
/// through the real runner and wait for it. The signal tests use this to deliver SIGINT/SIGTERM/SIGHUP while
/// a child group is live, before any real command exists. `SIDELOAD_TEST_SCRATCH` (with `SIDELOAD_TEST_MARKER`)
/// makes the hook create its own scratch folder, register it as an `inspect` scratch folder and write its path to
/// `<marker>.scratch`, so the tests can check that an interrupt removes it. The hook never registers a path given
/// from outside: only a folder this process has just made with `mkdtemp` can be deleted. Not reachable through argv.
func runTestSleepChild() async -> Envelope? {
    guard let raw = getenv("SIDELOAD_TEST_SLEEP_CHILD") else { return nil }
    // `SIDELOAD_TEST_RENEW_MOVED=<n>` registers, as `provision --renew` does before its build, a report of n moved
    // profiles with the CLI's real interrupt report, so the tests can see the signal handler's `INTERRUPTED` object
    // carry it. (`provision` itself needs a real xcodebuild, keychain and Xcode folders, which a test must not touch.)
    // `SIDELOAD_TEST_PROVISION_REGISTER` runs provision's own registration (the call `ProvisionCommand.run` makes at its
    // start) against the live services, so `$SIDELOAD_HOME`'s ledger decides what an interrupt reports.
    if getenv("SIDELOAD_TEST_PROVISION_REGISTER") != nil {
        let services = liveServices()
        ProvisionCommand.registerInterruptReport(services, record: ProvisionCommand.RenewRecord.read(services))
    }
    if let moved = getenv("SIDELOAD_TEST_RENEW_MOVED").flatMap({ Int(String(cString: $0)) }) {
        var outcome = ProfileCacheRenewal.Outcome()
        outcome.moved = moved
        outcome.movedTo = (0..<moved).map { "tmp/renewed-profile-00000000000\($0).mobileprovision" }
        let data: [String: JSONValue] = [
            "app": "stremio-ios", "device": "iphone", "bundleId": "io.github.dividedby.free.stremio",
        ].merging(outcome.json) { _, new in new }
        cliInterruptReport.set { data }
    }
    if getenv("SIDELOAD_TEST_SCRATCH") != nil, let marker = getenv("SIDELOAD_TEST_MARKER") {
        let base = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
        var template = Array((base + "/sideload-hook-XXXXXX").utf8CString)
        if mkdtemp(&template) != nil {
            let scratch = String(decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // An unreadable directory inside, as an extracted archive can have.
            mkdir(scratch + "/locked", 0o700)
            mkdir(scratch + "/locked/inner", 0o700)
            chmod(scratch + "/locked/inner", 0o000)
            chmod(scratch + "/locked", 0o000)
            _ = ScratchRegistry.shared.register(scratch)
            let file = String(cString: marker) + ".scratch"
            if let handle = fopen(file, "w") {
                fputs(scratch, handle)
                fclose(handle)
            }
        }
    }
    let result = await PosixSpawnRunner().run(CommandSpec(executable: String(cString: raw), timeout: .seconds(120)))
    return .result("test-sleep-child", [
        "timedOut": .bool(result.timedOut),
        "code": result.code.map { .number(Double($0)) } ?? .null,
    ])
}

/// Debug builds only: when `SIDELOAD_TEST_READY` names a file, write `ready\n` to it. `main.swift` calls this right
/// after `installInterruptHandlers`, so the tests can wait for it instead of sleeping before they send a signal.
/// Writes nothing when the variable is unset.
func writeTestReadyMarker() {
    guard let path = getenv("SIDELOAD_TEST_READY"), let handle = fopen(path, "w") else { return }
    fputs("ready\n", handle)
    fclose(handle)
}
#endif
