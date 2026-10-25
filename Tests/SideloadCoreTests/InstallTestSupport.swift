import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Fakes for `install`, `app remove` and `slot`: a runner that plays `devicectl` against a simulated app list (so the
// before/after snapshots and the delta are real), `codesign` and `security cms -D` for the free guard (the "CMS" file
// is the plist itself), and a signed app laid out on disk the way `sign` leaves it. No real devicectl, device, keychain
// or network.

let wdaId = "com.facebook.WebDriverAgentRunner.xctrunner"
let atvloadlyId = "com.atvloadly.stremio"
let sideStoreId = "com.SideStore.SideStore"

enum InstallBehaviour: Sendable {
    case succeed
    /// Exit 0 but the output does not name the bundle.
    case silentSuccess
    case fail(json: JSONValue?, stderr: String = "", code: Int32 = 1)
    case timeout
    /// A timeout, but the install finishes: the app is on the device afterwards.
    case timeoutLanding
}

/// A `device info apps` document that is not a complete listing (`AppSnapshot.parse` must reject each).
enum SnapshotFault: String, CaseIterable, Sendable {
    case noResult, emptyResult, appsNotArray, badElement, elementNotObject, emptyBundleId, notSuccess, topLevelArray

    var json: JSONValue {
        let ok: JSONValue = ["outcome": "success"]
        switch self {
        case .noResult: return ["info": ok]
        case .emptyResult: return ["info": ok, "result": [:]]
        case .appsNotArray: return ["info": ok, "result": ["apps": "oops"]]
        case .badElement: return ["info": ok, "result": ["apps": [["bundleIdentifier": 5]]]]
        case .elementNotObject: return ["info": ok, "result": ["apps": ["com.example.x"]]]
        case .emptyBundleId: return ["info": ok, "result": ["apps": [["bundleIdentifier": ""]]]]
        case .notSuccess: return ["info": ["outcome": "failed"], "result": ["apps": []]]
        case .topLevelArray: return [ok]
        }
    }
}

/// What `device profile list --type provisioning` does.
enum ProfileListBehaviour: Sendable, Equatable {
    /// A document shaped like the owner's phone: a free-team profile for every developer-built app on the device except
    /// `DeviceScript.otherTeamApps` (TestFlight betas: also developer-built, profiles under other teams), plus the
    /// `staleFreeProfiles` and some unrelated profiles.
    case derived
    case fail
    /// Exit 0 but not a complete listing.
    case malformed
}

struct DeviceScript: Sendable {
    /// The device's apps before the run: bundle ID to `builtByDeveloper`.
    var initial: [String: Bool] = [:]
    /// 1-based snapshot call numbers that fail.
    var snapshotFailures: Set<Int> = []
    /// 1-based snapshot call numbers that exit 0 but print a document that is not a complete listing.
    var snapshotShapes: [Int: SnapshotFault] = [:]
    var install = InstallBehaviour.succeed
    /// Apps that also appear (or vanish) when the install runs.
    var alsoAdded: [String: Bool] = [:]
    var alsoRemovedOnInstall: [String] = []
    /// An install that fails but lands the app anyway.
    var landsDespiteFailure = false
    var uninstallFailure: JSONValue?
    /// The uninstall reports `uninstallFailure` but removes the app anyway.
    var uninstallFailureRemoves = false
    /// A timed-out install that is not on the device when the call returns finishes this many seconds later (the clock
    /// the runner watches must reach that time before the app shows in a snapshot).
    /// A timed-out call keeps the process busy for its whole timeout: the clock moves by it before the call returns, and the
    /// "lands later" delays count from then. Off by default; the random walk turns it on.
    var timeoutsTakeTime = false
    var installLandsAfter: TimeInterval?
    /// Same for a timed-out uninstall that did not remove the app yet (`uninstallTimeoutRemoves == false`).
    var uninstallLandsAfter: TimeInterval?
    /// The uninstall times out (nil: it does not). True: the app is gone anyway; false: it is still there.
    var uninstallTimeoutRemoves: Bool?
    /// The uninstall reports success but the app stays on the device.
    var uninstallLeavesApp = false
    /// The install reports success (naming the bundle) but the app never shows up in the app list.
    var installLeavesApp = false
    var alsoRemovedOnUninstall: [String] = []
    /// The team `codesign -dvv` reports for the signed app.
    var reportedTeam: String? = Team.free
    var leaf: Data?
    /// How a scripted timeout reaches sideload. Each one leaves the device op's result unknown.
    var timeoutShape = TimeoutShape.runnerKill
    var profileList = ProfileListBehaviour.derived
    /// Developer-built apps whose profile belongs to another team (TestFlight betas).
    var otherTeamApps: Set<String> = []
    /// Free-team profiles whose app is not on the device (profiles outlive their app).
    var staleFreeProfiles: [String] = []
    /// The data container every app on the device starts with: relative path to content (`DataFaults` breaks it).
    var container: [String: Data] = [:]
    var dataFaults = DataFaults()
}

/// How the app-data calls (`device info files`, `device copy from|to`) misbehave on the simulated device.
struct DataFaults: Sendable {
    /// `device info files` fails.
    var listFails = false
    /// `device info files` prints a document that is not a listing.
    var listMalformed = false
    /// Device paths whose `copy from` fails.
    var copyFromFails: Set<String> = []
    /// Device paths whose `copy from` writes one byte too few (every time).
    var copyFromShort: Set<String> = []
    /// Device paths whose `copy to` fails.
    var copyToFails: Set<String> = []
    /// `copy to` reports success but nothing arrives (the relisting then disagrees).
    var copyToDrops = false
    /// The listing carries no sizes.
    var noSizes = false
    /// Every data call takes this long on the clock the runner watches.
    var callTakes: TimeInterval = 0
    /// Every copy hangs until the Runner has killed it, as late as it can: `--timeout` + the Runner's margin + its worst-case
    /// overrun (the worst case of the time cap).
    var copyHangs = false
    /// Device paths whose `copy from` leaves a symlink at the destination, pointing at this (outside) folder, and reports success.
    var copyFromSymlinks: [String: String] = [:]
    /// Sizes the listing claims for some paths, whatever the content is.
    var claimedSizes: [String: Int] = [:]
    /// The listing fails the n-th time it is asked (1-based), whatever else it does.
    var listFailsOn: Set<Int> = []
}

/// Every way a device op can end without a known result, as devicectl, the runner and the call chain produce them.
enum TimeoutShape: CaseIterable, Sendable {
    /// The runner killed devicectl after `timeoutSec + 15`: no exit code, `timedOut`.
    case runnerKill
    /// devicectl's own `--timeout` fired first: a non-zero exit with "timed out" on stderr, `timedOut` false.
    case devicectlOwn
    /// The output passed the runner's cap; the run was cut off.
    case overflow
    /// The child was killed by a signal: no exit code, no timeout flag, no spawn error.
    case signalKill
    /// The call threw before it returned (here: `DeviceCtl` cannot read the config). The device still does what the script
    /// says. Only `runSlotCommand(..., thrown: true)` can produce it; the runner alone returns a kill for this shape.
    case thrown

    var result: RunResult {
        switch self {
        case .runnerKill, .thrown: RunResult(code: nil, timedOut: true)
        case .devicectlOwn: RunResult(code: 1, stderr: "ERROR: The operation timed out. (com.apple.dt.CoreDeviceError error 4)")
        case .overflow: RunResult(code: nil, overflow: true)
        case .signalKill: RunResult(code: nil, signal: 9)
        }
    }
}

final class DeviceSimRunner: Runner {
    private let recorded = Mutex<[CommandSpec]>([])
    private let apps: Mutex<[String: Bool]>
    private let snapshots = Mutex(0)
    private let listings = Mutex(0)
    /// Each app's data container, by bundle ID; seeded from the script on first use, emptied by an uninstall.
    private let containers = Mutex<[String: [String: Data]]>([:])
    private let armed: Mutex<DeviceScript>
    /// Operations that finish later, by the clock: (when, bundle ID, true for an install).
    private let deferred = Mutex<[(at: Date, id: String, install: Bool, copy: Date)]>([])
    /// The profile expiry of the copy of each app on the device (what a real install of that build carries). An install
    /// takes the build's expiry at the moment of the call; apps the device starts with carry the first build's.
    private let copies: Mutex<[String: Date]>
    private let buildClock = Mutex(daysFromNow(5))
    /// The expiry of the signed build the next install will put on the device (a test "re-signs" by moving it).
    var buildExpiry: Date {
        get { buildClock.withLock { $0 } }
        set { buildClock.withLock { $0 = newValue } }
    }
    /// The expiry of the copy of `id` on the device now, or once every operation in flight has landed; nil when it is not there.
    func copyExpiry(_ id: String, eventually: Bool) -> Date? {
        guard (eventually ? deviceAppsEventually : deviceApps)[id] != nil else { return nil }
        var copy = copies.withLock { $0[id] }
        if eventually {
            for op in deferred.withLock({ $0 }).sorted(by: { $0.at < $1.at }) where op.install && op.id == id { copy = op.copy }
        }
        return copy
    }
    /// The time source for deferred completions; nil means nothing is ever deferred.
    private let watched = Mutex<MutableClock?>(nil)
    private let installHook = Mutex<(@Sendable () -> Void)?>(nil)
    /// Called at the moment of each `device install app` call, before the fake device acts (to inspect durable state).
    var onInstall: (@Sendable () -> Void)? {
        get { installHook.withLock { $0 } }
        set { installHook.withLock { $0 = newValue } }
    }
    var clock: MutableClock? {
        get { watched.withLock { $0 } }
        set { watched.withLock { $0 = newValue } }
    }

    init(_ script: DeviceScript) {
        armed = Mutex(script)
        apps = Mutex(script.initial)
        copies = Mutex(script.initial.mapValues { _ in daysFromNow(5) })
    }

    /// Applies the deferred operations that are due by the clock.
    private func landDue() {
        guard let now = clock?.now() else { return }
        let due = deferred.withLock { list -> [(at: Date, id: String, install: Bool, copy: Date)] in
            let due = list.filter { $0.at <= now }.sorted { $0.at < $1.at }
            list.removeAll { $0.at <= now }
            return due
        }
        apps.withLock { state in
            for op in due { state[op.id] = op.install ? true : nil }
        }
        copies.withLock { state in for op in due where op.install { state[op.id] = op.copy } }
    }

    /// The apps once every deferred operation has finished (nothing is applied: the clock does not move).
    var deviceAppsEventually: [String: Bool] {
        var state = deviceApps
        for op in deferred.withLock({ $0 }).sorted(by: { $0.at < $1.at }) { state[op.id] = op.install ? true : nil }
        return state
    }

    /// An operation that is already running (its process was killed, say) and finishes `seconds` from now.
    func scheduleLanding(_ id: String, install: Bool, after seconds: TimeInterval) {
        defer_(seconds, id: id, install: install)
    }

    private func defer_(_ seconds: TimeInterval?, id: String, install: Bool) {
        guard let seconds, let clock else { return }
        deferred.withLock { $0.append((clock.now().addingTimeInterval(seconds), id, install, buildExpiry)) }
    }

    var script: DeviceScript { armed.withLock { $0 } }

    /// Replaces the faults for the next command and restarts the snapshot numbering. The apps on the device stay.
    func arm(_ script: DeviceScript) {
        armed.withLock { current in
            var next = script
            if next.leaf == nil { next.leaf = current.leaf }  // the signing certificate the guard compares against
            current = next
        }
        snapshots.withLock { $0 = 0 }
    }

    /// Puts an app on or takes it off the device behind sideload's back (an owner action in a test).
    func setApp(_ id: String, _ developer: Bool?) {
        apps.withLock { $0[id] = developer }
        if developer != nil { copies.withLock { $0[id] = buildExpiry } }
    }

    var calls: [CommandSpec] { recorded.withLock { $0 } }
    var deviceApps: [String: Bool] {
        landDue()
        return apps.withLock { $0 }
    }

    /// The devicectl subcommands in order: `info apps`, `install app`, `uninstall app`. The read-only `profile list` and the
    /// app-data calls are left out (see `profileCalls`, `dataCalls`) so these sequences keep showing the snapshot/op order.
    var deviceCalls: [String] {
        calls.filter { $0.executable == "xcrun" && $0.args.first == "devicectl" }.map(Self.words)
            .filter { $0 != "device profile list" && !Self.dataWords.contains($0) }
    }

    static let dataWords: Set<String> = ["device info files", "device copy from", "device copy to"]

    /// The app-data calls (`info files`, `copy from`, `copy to`), in order.
    var dataCalls: [CommandSpec] { calls.filter { $0.executable == "xcrun" && Self.dataWords.contains(Self.words($0)) } }

    /// The content of the data container of `id` on the device now.
    func container(_ id: String) -> [String: Data] {
        let seed = script.container
        return containers.withLock { $0[id] ?? seed }
    }

    /// Changes the container behind sideload's back (an owner action: the app wrote something).
    func setContainer(_ id: String, _ files: [String: Data]) { containers.withLock { $0[id] = files } }

    /// The argv of every `device profile list` call.
    var profileCalls: [CommandSpec] { calls.filter { $0.executable == "xcrun" && Self.words($0) == "device profile list" } }

    /// Every argv element of every devicectl call, for "this ID never appeared" checks.
    var deviceArgv: [String] { calls.filter { $0.executable == "xcrun" }.flatMap(\.args) }

    var installCalls: [CommandSpec] { calls.filter { $0.executable == "xcrun" && Self.words($0) == "device install app" } }

    static func words(_ spec: CommandSpec) -> String {
        spec.args.dropFirst().prefix { !$0.hasPrefix("-") }.joined(separator: " ")
    }

    func run(_ spec: CommandSpec) async -> RunResult {
        recorded.withLock { $0.append(spec) }
        switch spec.executable {
        case "xcrun": return devicectl(spec)
        case "/usr/bin/codesign": return codesign(spec)
        case "/usr/bin/security":
            guard spec.args.count == 4, spec.args.prefix(3) == ["cms", "-D", "-i"],
                let text = try? String(contentsOfFile: spec.args[3], encoding: .utf8)
            else { return RunResult(code: 1) }
            return RunResult(stdout: text)
        default: return RunResult()
        }
    }

    private func write(_ json: JSONValue, _ spec: CommandSpec) {
        if let path = spec.args.firstIndex(of: "--json-output").map({ spec.args[$0 + 1] }),
            let data = try? JSONEncoder().encode(json)
        {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func devicectl(_ spec: CommandSpec) -> RunResult {
        let script = self.script
        landDue()
        switch Self.words(spec) {
        case "device info apps":
            let n = snapshots.withLock { value in
                value += 1
                return value
            }
            if script.snapshotFailures.contains(n) { return RunResult(code: 1) }
            if let fault = script.snapshotShapes[n] {
                write(fault.json, spec)
                return RunResult()
            }
            write(appsJSON(deviceApps), spec)
            return RunResult()
        case "device profile list":
            switch script.profileList {
            case .fail: return RunResult(code: 1)
            case .malformed:
                write(["info": ["outcome": "success"], "result": ["provisioningProfiles": [["teamIdentifier": 5]]]], spec)
            case .derived:
                func profile(_ team: String, _ id: String) -> JSONValue {
                    ["teamIdentifier": .string(team), "appIdentifier": .string("\(team).\(id)"), "name": "P", "hasExpired": false]
                }
                var rows: [JSONValue] = [profile("TFTEAM0001", "com.example.testflight.beta")]
                let current = deviceApps
                for (id, developer) in current.sorted(by: { $0.key < $1.key }) where developer {
                    rows.append(profile(script.otherTeamApps.contains(id) ? "TFTEAM0002" : Team.free, id))
                }
                for id in script.staleFreeProfiles { rows.append(profile(Team.free, id)) }
                write(["info": ["outcome": "success"], "result": ["provisioningProfiles": .array(rows), "configurationProfiles": []]], spec)
            }
            return RunResult()
        case "device install app":
            onInstall?()
            let id = installedBundle(spec)
            defer {
                // A reinstall that loses the app (or an unrelated removal), whatever the install itself reported.
                if !script.alsoRemovedOnInstall.isEmpty {
                    apps.withLock { state in for gone in script.alsoRemovedOnInstall { state[gone] = nil } }
                }
            }
            switch script.install {
            case .succeed, .silentSuccess:
                // "Reports success but the app never shows up" only makes sense for an app that was not there: over an
                // existing copy a successful install replaces it.
                let there = apps.withLock { $0[id] != nil }
                let lands = !script.installLeavesApp || there
                apps.withLock { state in
                    if lands { state[id] = true }
                    for (extra, developer) in script.alsoAdded { state[extra] = developer }
                }
                if lands { copies.withLock { $0[id] = buildExpiry } }
                if case .succeed = script.install {
                    write(["info": ["outcome": "success"], "result": ["installedApplications": [["bundleID": .string(id)]]]], spec)
                } else {
                    write(["info": ["outcome": "success"], "result": [:]], spec)
                }
                return RunResult()
            case .fail(let json, let stderr, let code):
                if script.landsDespiteFailure {
                    apps.withLock { $0[id] = true }
                    copies.withLock { $0[id] = buildExpiry }
                }
                if let json { write(json, spec) }
                return RunResult(code: code, stderr: stderr)
            case .timeout, .timeoutLanding:
                timedOutOp(install: true, id: id)
                return script.timeoutShape.result
            }
        case "device uninstall app":
            if script.uninstallTimeoutRemoves != nil {
                timedOutOp(install: false, id: spec.args.last ?? "")
                return script.timeoutShape.result
            }
            if let failure = script.uninstallFailure {
                if script.uninstallFailureRemoves { apps.withLock { $0[spec.args.last ?? ""] = nil } }
                write(failure, spec)
                return RunResult(code: 1)
            }
            let id = spec.args.last ?? ""
            apps.withLock { state in
                if !script.uninstallLeavesApp { state[id] = nil }
                for gone in script.alsoRemovedOnUninstall { state[gone] = nil }
            }
            containers.withLock { $0[id] = [:] }  // an uninstall deletes the app's data
            write(["info": ["outcome": "success"], "result": [:]], spec)
            return RunResult()
        case "device info files", "device copy from", "device copy to":
            return dataCall(spec, script.dataFaults)
        default:
            return RunResult(code: 1)
        }
    }

    private func flagValue(_ flag: String, _ spec: CommandSpec) -> String {
        spec.args.firstIndex(of: flag).map { spec.args[$0 + 1] } ?? ""
    }

    /// `info files`, `copy from` and `copy to` against the simulated container of the named app.
    private func dataCall(_ spec: CommandSpec, _ faults: DataFaults) -> RunResult {
        if faults.callTakes > 0 { clock?.advance(faults.callTakes) }
        if faults.copyHangs, Self.words(spec) != "device info files" {
            clock?.advance(Double((Int(flagValue("--timeout", spec)) ?? 0) + AppDataBackup.runnerGraceSec))
            return RunResult(code: nil, timedOut: true)
        }
        let id = flagValue("--domain-identifier", spec)
        let seed = script.container
        func files() -> [String: Data] { containers.withLock { $0[id] ?? seed } }
        func store(_ change: (inout [String: Data]) -> Void) {
            containers.withLock { state in
                var current = state[id] ?? seed
                change(&current)
                state[id] = current
            }
        }
        switch Self.words(spec) {
        case "device info files":
            let n = listings.withLock { value in
                value += 1
                return value
            }
            if faults.listFails || faults.listFailsOn.contains(n) { return RunResult(code: 1) }
            if faults.listMalformed {
                write(["info": ["outcome": "success"], "result": ["files": "oops"]], spec)
                return RunResult()
            }
            let current = files()
            var rows: [JSONValue] = []
            var directories = Set<String>()
            for path in current.keys {
                // Parent rows only for well-formed paths (a hostile test path is listed as it is, without invented parents).
                guard !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains($0) })
                else { continue }
                var parts = path.split(separator: "/").dropLast()
                while !parts.isEmpty {
                    directories.insert(parts.joined(separator: "/"))
                    parts = parts.dropLast()
                }
            }
            // The shape devicectl prints: name, relativePath, metadata and resources; directories are entries too.
            func row(_ path: String, size: Int?) -> JSONValue {
                var metadata: [String: JSONValue] = [:]
                if let size { metadata["size"] = .number(Double(size)) }
                return [
                    "name": .string(path.split(separator: "/").last.map(String.init) ?? path), "relativePath": .string(path),
                    "metadata": .object(metadata), "resources": [:],
                ]
            }
            for dir in directories.sorted() { rows.append(row(dir, size: nil)) }
            for (path, data) in current.sorted(by: { $0.key < $1.key }) {
                rows.append(row(path, size: faults.noSizes ? nil : (faults.claimedSizes[path] ?? data.count)))
            }
            write(["info": ["outcome": "success"], "result": ["files": .array(rows)]], spec)
            return RunResult()
        case "device copy from":
            let source = flagValue("--source", spec)
            let destination = flagValue("--destination", spec)
            if faults.copyFromFails.contains(source) { return RunResult(code: 1) }
            if let target = faults.copyFromSymlinks[source] {
                try? makeDirectories(parentPath(destination), mode: 0o700)
                return symlink(target, destination) == 0 ? RunResult() : RunResult(code: 1)
            }
            let current = files()
            guard let data = current[source] else {
                // A directory has nothing to copy; anything else is not there.
                return current.keys.contains { $0.hasPrefix(source + "/") } ? RunResult() : RunResult(code: 1)
            }
            let bytes = faults.copyFromShort.contains(source) ? data.dropLast() : data
            do {
                try makeDirectories(parentPath(destination), mode: 0o700)
                try Data(bytes).write(to: URL(fileURLWithPath: destination))
                chmod(destination, 0o644)  // devicectl's own mode; backup tightens it
            } catch {
                return RunResult(code: 1)
            }
            return RunResult()
        default:  // device copy to
            let source = flagValue("--source", spec)
            let destination = flagValue("--destination", spec)
            if faults.copyToFails.contains(destination) { return RunResult(code: 1) }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: source)) else { return RunResult(code: 1) }
            if !faults.copyToDrops { store { $0[destination] = data } }
            return RunResult()
        }
    }

    /// What a timed-out op does to the device: it takes the clock's time, then either finishes at once, finishes later, or
    /// never does (per the script). Shared by the runner's own timeout and by a thrown call, whose op never reached this
    /// runner but may still have been running.
    private func timedOutOp(install: Bool, id: String) {
        let script = self.script
        if install {
            if script.timeoutsTakeTime { clock?.advance(Double(SlotState.installTimeoutSec) + 15) }
            if case .timeoutLanding = script.install {
                apps.withLock { $0[id] = true }
                copies.withLock { $0[id] = buildExpiry }
            } else {
                defer_(script.installLandsAfter, id: id, install: true)
            }
        } else {
            if script.timeoutsTakeTime { clock?.advance(Double(SlotState.uninstallTimeoutSec) + 15) }
            if script.uninstallTimeoutRemoves == true {
                apps.withLock { $0[id] = nil }
            } else {
                defer_(script.uninstallLandsAfter, id: id, install: false)
            }
        }
    }

    /// A call that threw before it reached this runner: the device still behaves as a timed-out op would. False when the
    /// script's op is not a timeout (then the call is left to run normally).
    func bypassOp(install: Bool, id: String) -> Bool {
        let script = self.script
        if install {
            switch script.install {
            case .timeout, .timeoutLanding: break
            default: return false
            }
        } else if script.uninstallTimeoutRemoves == nil {
            return false
        }
        timedOutOp(install: install, id: id)
        return true
    }

    /// The bundle ID of the app at the install's positional path (its Info.plist).
    private func installedBundle(_ spec: CommandSpec) -> String {
        let path = (spec.args.last ?? "") + "/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return "" }
        return plist["CFBundleIdentifier"] as? String ?? ""
    }

    private func codesign(_ spec: CommandSpec) -> RunResult {
        if spec.args.first == "-dvv" {
            let path = (spec.args.last ?? "") + "/Info.plist"
            let plist = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            }
            let team = script.reportedTeam.map { "TeamIdentifier=\($0)" } ?? "TeamIdentifier=not set"
            return RunResult(stderr: "Identifier=\(plist?["CFBundleIdentifier"] as? String ?? "")\n\(team)\n")
        }
        if let flag = spec.args.first(where: { $0.hasPrefix("--extract-certificates=") }) {
            if let leaf = script.leaf {
                FileManager.default.createFile(atPath: String(flag.dropFirst("--extract-certificates=".count)) + "0", contents: leaf)
            }
            return RunResult()
        }
        return RunResult(code: 1)  // `-d --entitlements`: unreadable, which the guard skips
    }
}

func appsJSON(_ apps: [String: Bool]) -> JSONValue {
    [
        "info": ["outcome": "success"],
        "result": [
            "apps": .array(
                apps.keys.sorted().map { id in
                    ["bundleIdentifier": .string(id), "builtByDeveloper": .bool(apps[id] ?? false), "name": "App"]
                })
        ],
    ]
}

struct InstallWorld {
    let paths: Paths
    let store: ConfigStore
    let services: Services
    let runner: DeviceSimRunner
    let app: ProvisionApp
    let keychain: SequencedKeychain
    let clock: MutableClock

    var alias: String { app.devicePlatform == "tvos" ? "appletv" : "iphone" }
    var bundleId: String { carrierPrefix + ".free." + app.suffix }
    var key: String { "\(alias)/\(app.rawValue)" }
    var seed: String { app.devicePlatform == "tvos" ? "2" : "1" }
    var appName: String { app == .apollo ? "Apollo" : app == .filler ? "Carrier" : "Stremio" }
    var signedApp: String { "\(paths.signedBuilds)/\(app.rawValue)/\(alias)/\(appName).app" }

    func ledger() throws -> Ledger { try services.ledgerStore.load() }
    /// The ledger's `installs[]`, empty when the ledger cannot be read (a test then fails on what it expects).
    var installs: [LedgerInstall] { (try? ledger().installs) ?? [] }
    var lent: [LedgerLent] { (try? ledger().lent) ?? [] }
    func device(_ alias: String) -> SavedDevice? { (try? config())?.devices[alias] }
    func config() throws -> Config { try store.load() }

    func install(app: String? = nil, device: String? = nil, yes: Bool = true) async -> Envelope {
        await InstallCommand.run(services, InstallOptions(app: app ?? self.app.rawValue, device: device ?? alias, yes: yes))
    }

    func remove(app: String? = nil, device: String? = nil, yes: Bool = true) async -> Envelope {
        await AppCommand.run(services, AppOptions(sub: "remove", app: app ?? self.app.rawValue, device: device ?? alias, yes: yes))
    }

    func slot(_ sub: String, device: String? = nil, udid: String? = nil, to: String? = nil) async -> Envelope {
        await SlotCommand.run(services, SlotOptions(sub: sub, device: device, udid: udid, to: to))
    }

    /// The printed (redacted) text must hold no device ID or name.
    func expectClean(_ envelope: Envelope, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = try envelope.printed().text
        for secret in [savedUdid("1"), savedCoreId("1"), savedUdid("2"), savedCoreId("2"), "Test iPhone", "Test Apple TV"] {
            #expect(!text.contains(secret), "output holds \(secret)", sourceLocation: sourceLocation)
        }
    }
}

/// Runs `body` against a temp home with `app` fetched-signed-provisioned: the signed app on disk, `freeSigned` and
/// `freeProfiles` in the ledger, the identity pinned, and the saved iPhone / Apple TV.
func withInstallWorld(
    app: ProvisionApp = .stremioIOS, alsoSigned: [ProvisionApp] = [], script: DeviceScript = DeviceScript(), reserved: Int = 0,
    lendable: String? = nil, signed: Bool = true, profileDays: Double = 5, embeddedDays: Double? = nil,
    embeddedTeam: String = Team.free, keychain reads: [[KeychainCertificate]?]? = nil, ledger tweak: ((inout Ledger) -> Void)? = nil,
    _ body: (InstallWorld) async throws -> Void
) async throws {
    let free = try freeKeychainCert()
    let freeDER = try certDER(TestCerts.free)
    var script = script
    if script.leaf == nil { script.leaf = freeDER }
    var devices = twoDevices
    devices["iphone"]?.lendableApp = lendable
    try devices["iphone"]?.setFreeSlotsReserved(reserved)
    let config = Config(
        devices: devices, bundleIdPrefix: carrierPrefix,
        extra: ["freeTeam": ["certFp8": .string(LedgerSync.fp8(free.reference))]])
    try await withTestHome(config: config) { paths, store in
        let uuid = "0F0F0F0F-1111-2222-3333-444444444444"
        let expires = daysFromNow(profileDays)
        if signed {
            var signedRecords: [LedgerFreeSigned] = []
            var profileRecords: [LedgerFreeProfile] = []
            for each in [app] + alsoSigned {
                let alias = each.devicePlatform == "tvos" ? "appletv" : "iphone"
                let seed = each.devicePlatform == "tvos" ? "2" : "1"
                let bundleId = carrierPrefix + ".free." + each.suffix
                let name = each == .apollo ? "Apollo" : each == .filler ? "Carrier" : "Stremio"
                let dir = "\(paths.signedBuilds)/\(each.rawValue)/\(alias)/\(name).app"
                try makeDirectories(dir, mode: 0o700)
                let info = try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": bundleId, "CFBundleExecutable": name], format: .xml, options: 0)
                try info.write(to: URL(fileURLWithPath: dir + "/Info.plist"))
                let xml = try profileXML(
                    uuid: uuid, team: embeddedTeam, applicationIdentifier: Team.free + "." + bundleId, devices: [savedUdid(seed)],
                    certs: [freeDER], platform: [each.profilePlatform], created: daysFromNow(-2),
                    expires: embeddedDays.map(daysFromNow) ?? expires)
                try Data(xml.utf8).write(to: URL(fileURLWithPath: dir + "/embedded.mobileprovision"))
                signedRecords.append(
                    LedgerFreeSigned(
                        id: "\(alias)/\(each.rawValue)", device: alias, app: each.rawValue, bundleId: bundleId, version: "1.2.3",
                        sha256Prefix: "abcd1234", profileUuid: uuid, profileExpires: expires, certFp8: LedgerSync.fp8(free.reference),
                        signedAt: daysFromNow(-1), path: "builds/signed/\(each.rawValue)/\(alias)/\(name).app",
                        strippedExtensions: [LedgerStrippedExtension(path: "PlugIns/W.appex", bundleId: "x.widget")],
                        droppedEntitlements: ["aps-environment"]))
                profileRecords.append(
                    LedgerFreeProfile(
                        id: "\(alias)/\(each.rawValue)", device: alias, deviceTail: Redactor.tail4(savedUdid(seed)), app: each.rawValue,
                        bundleId: bundleId, profileUuid: uuid, created: daysFromNow(-2), expires: expires,
                        certFp8: LedgerSync.fp8(free.reference), file: "profiles/free/\(each.rawValue)/\(alias)/\(uuid).mobileprovision"))
            }
            try await LedgerStore(paths: paths).update { ledger in
                ledger.freeSigned = signedRecords
                ledger.freeProfiles = profileRecords
            }
        }
        if let tweak { try await LedgerStore(paths: paths).update { tweak(&$0) } }
        let runner = DeviceSimRunner(script)
        runner.buildExpiry = expires  // what an install puts on the device; the apps it starts with carry the first build's (+5 d)
        let clock = MutableClock(testNow)
        runner.clock = clock
        let keychain = SequencedKeychain(reads ?? [[free]])
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: clock, keychain: keychain, home: paths)
        try await body(InstallWorld(paths: paths, store: store, services: services, runner: runner, app: app, keychain: keychain, clock: clock))
    }
}

/// A wall clock a test moves by hand; the simulated device watches it for deferred completions.
final class MutableClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ instant: Date) { current = instant }

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A reference cell a test closure can write to.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Forwards to the simulated device and tells a test about each call before it runs.
struct DeviceSimRunnerWatch: Runner {
    let inner: DeviceSimRunner
    let onCall: @Sendable (CommandSpec) -> Void

    func run(_ spec: CommandSpec) async -> RunResult {
        onCall(spec)
        return await inner.run(spec)
    }
}
