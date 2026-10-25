import Foundation
import Testing

@testable import SideloadCore

// The random walk of the unified pending-operation model: 20 seeds x 500 steps over every command (lend, return, remove and
// install of two apps, status), with random device faults (every unknown-result shape, failed and malformed snapshots, ops
// that land late), random crash points at every durable write, random clock jumps of 0 to 1000 s, and a signed build that
// comes and goes. After every step the invariants of docs/design.md section 18 are checked against the true state of the
// simulated device (I1 to I9), and again once everything in flight has landed.

@Suite("slot model: random walk with crash injection and late landings")
struct SlotWalkTests {
    @Test("random sequences of lend, return, remove, install and status (500 steps)", arguments: Array(1...20))
    func randomSequences(seed: Int) async throws {
        // At most three walks at a time: the other suites include timing-sensitive process tests that a saturated CPU fails.
        await walkGate.enter()
        defer { Task { await walkGate.leave() } }
        let locked = try loadFixtureJSON("install-locked.json")
        let limit = try loadFixtureJSON("install-free-app-limit.json")
        var rng = SplitMix64(seed: UInt64(seed))
        try await withInstallWorld(
            app: .stremioIOS, alsoSigned: [.apollo], script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios",
            ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            var visited = Set<SlotPhase>()
            var gated = 0
            var reinstallKept = 0
            var signing = Signing.valid
            var validSigned = try w.ledger().freeSigned
            var buildDays = 5.0
            for step in 0..<500 {
                let label = "seed \(seed) step \(step)"
                // A new build is signed now and then (a later expiry). The device keeps whatever copy it was given.
                if Int.random(in: 0..<10, using: &rng) == 0 {
                    buildDays += 1
                    w.runner.buildExpiry = daysFromNow(buildDays)
                    validSigned = validSigned.map { var r = $0; r.profileExpires = daysFromNow(buildDays); return r }
                    try await signing.apply(to: w, valid: validSigned)
                }
                if Int.random(in: 0..<25, using: &rng) == 0 {
                    signing = [Signing.valid, .valid, .unsigned, .expired].randomElement(using: &rng) ?? .valid
                    try await signing.apply(to: w, valid: validSigned)
                }

                let action = Int.random(in: 0..<12, using: &rng)
                var script = randomScript(&rng, locked: locked, limit: limit)
                // A device may finish a timed-out operation later. The install only matters for return and install, the
                // uninstall for lend and remove.
                let installs = (3..<6).contains(action) || (7..<10).contains(action)
                if !installs { script.installLandsAfter = nil }
                if installs { script.uninstallLandsAfter = nil }
                w.runner.arm(script)
                w.clock.advance([0, 0, 0, 5, 30, 120, 301, 700, 1000].randomElement(using: &rng) ?? 0)

                let kind: SlotCommandKind
                var app = "stremio-ios"
                switch action {
                case 0..<3: kind = .lend
                case 3..<6: kind = .giveBack
                case 6: kind = .remove
                case 7, 8: kind = .install
                case 9:
                    kind = .install
                    app = "apollo"
                case 10:
                    kind = .remove
                    app = "apollo"
                default: kind = .lend  // status below
                }
                let isStatus = action == 11
                let before = try w.ledger()
                let nowBefore = w.clock.now()
                let crashAt = Int.random(in: 0..<8, using: &rng) == 0 ? crashPoints.randomElement(using: &rng) : nil

                let out: Envelope
                if isStatus {
                    out = StatusCommand.run(w.services)
                } else {
                    // I1 at the runner; I8 at every durable write.
                    let paths = w.paths
                    let watcher = opWatcher(w) { label }
                    out = await runSlotCommand(
                        kind, w, app: app, crashAt: crashAt, thrown: script.timeoutShape == .thrown, runner: watcher,
                        watch: { point in
                            guard let ledger = try? LedgerStore(paths: paths).load() else { return }
                            var projected = ledger
                            SlotRule.project(&projected)
                            #expect(projected == ledger, "\(label): I8 after the write at \(point)")
                        })
                }
                let after = try w.ledger()

                // I3: a record whose op was inside its window before the command is untouched by it.
                expectPendingUntouched(before: before, after: after, at: nowBefore, label: label)
                try expectSlotModel(w, label: label)
                try expectSlotModel(w, label: label, eventually: true)  // a late landing must not contradict the ledger either
                try expectStatusNeverOptimistic(w, label: label)
                try w.expectClean(out)
                // I7: a slot becomes lent only in a run where the signed build was valid.
                for slot in after.slots where slot.lentTo != nil {
                    if before.slots.first(where: { $0.id == slot.id })?.lentTo == nil {
                        #expect(signing == .valid, "\(label): I7 \(slot.id) was lent with the signed build \(signing)")
                    }
                }

                // Nothing is claimed that the device does not show.
                let there = w.runner.deviceApps
                let printed = json(out)
                if !isStatus && out.ok {
                    switch kind {
                    case .lend: #expect(there[stremioId] == nil, "\(label): lend ok but the app is on the device")
                    case .giveBack: if printed["reinstalled"] == true { #expect(there[stremioId] != nil, "\(label): return ok but the app is not back") }
                    case .remove: if printed["removed"] == true { #expect(there[w.bundleId(of: app)] == nil, "\(label): remove ok but the app is on the device") }
                    case .install: #expect(there[w.bundleId(of: app)] != nil, "\(label): install ok but the app is not on the device")
                    }
                }
                if !isStatus, out.errorCodes == ["SLOT_PENDING"] {
                    gated += 1
                    #expect(printed["freed"] == 0 && printed["retryAfter"] != nil, "\(label): a gate answer claims nothing")
                }
                if after.slots.contains(where: { $0.op?.kind == .reinstall }) { reinstallKept += 1 }

                // Status: a pending or lent record is never free, and `holds` only for lent.
                let status = json(StatusCommand.run(w.services))
                let entry = try w.ledger().lent.first
                visited.insert(SlotPhase(entry))
                let iphone = status["slots"]?["devices"]?.array?.first { $0["alias"] == "iphone" }
                if let entry {
                    #expect(iphone?["used"] != 0 && iphone?["used"] != nil, "\(label): a record counts as used")
                    #expect(iphone?["lent"]?["state"] == .string(entry.state))
                    #expect(iphone?["pending"] == .bool(SlotPhase(entry).pending || after.slots.contains { $0.op != nil }))
                    #expect(status["lent"]?.array?.first?["holds"] == .bool(SlotPhase(entry) == .lent))
                }
            }
            // The walk is not vacuous: it reached every state, kept a reinstall pending, and was gated.
            #expect(visited == Set(SlotPhase.allCases), "seed \(seed) visited \(visited)")
            #expect(gated > 0 && reinstallKept > 0, "seed \(seed): gated \(gated), reinstall kept \(reinstallKept)")
        }
    }
}

/// The signed build `lend` needs: valid, gone, or expired. I7 is checked against it.
private enum Signing: Sendable {
    case valid, unsigned, expired

    /// Puts the ledger's `freeSigned` records in this state; `valid` is what the world was built with.
    func apply(to w: InstallWorld, valid records: [LedgerFreeSigned]) async throws {
        try await w.services.ledgerStore.update { ledger in
            switch self {
            case .valid: ledger.freeSigned = records
            case .unsigned: ledger.freeSigned = []
            case .expired:
                ledger.freeSigned = records.map {
                    var expired = $0
                    expired.profileExpires = testNow.addingTimeInterval(-86_400)
                    return expired
                }
            }
        }
    }
}

/// Bounds how many random walks run at once.
private actor WalkGate {
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let limit = 3

    func enter() async {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

private let walkGate = WalkGate()

private let crashPoints = [
    "migrate", "lend.settle", "lend.intent", "lend.final", "return.settle", "return.intent", "return.final",
    "remove.settle", "remove.intent", "remove.final", "install.settle", "install.intent", "install.final",
]

private func randomScript(_ rng: inout SplitMix64, locked: JSONValue, limit: JSONValue) -> DeviceScript {
    func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    var script = DeviceScript()
    script.timeoutsTakeTime = chance(0.7)
    // Every way an op can end unknown: the draw covers the runner's kill, devicectl's own timeout, an overflow, a signal kill
    // and a thrown call.
    script.timeoutShape = TimeoutShape.allCases.randomElement(using: &rng) ?? .runnerKill
    for call in 1...3 where chance(0.12) { script.snapshotFailures.insert(call) }
    if chance(0.06) { script.snapshotShapes[Int.random(in: 1...3, using: &rng)] = SnapshotFault.allCases.randomElement(using: &rng) }
    let roll = Double.random(in: 0..<1, using: &rng)
    switch roll {
    case ..<0.55: script.install = .succeed
    case ..<0.62: script.install = .silentSuccess
    case ..<0.73: script.install = .fail(json: locked)
    case ..<0.76: script.install = .fail(json: limit)
    case ..<0.88: script.install = .timeout
    default: script.install = .timeoutLanding
    }
    script.landsDespiteFailure = chance(0.3)
    if chance(0.1) {
        script.uninstallFailure = locked
        script.uninstallFailureRemoves = chance(0.4)
    }
    if chance(0.2) {
        script.uninstallTimeoutRemoves = chance(0.5)
        if script.uninstallTimeoutRemoves == false, chance(0.6) { script.uninstallLandsAfter = Double(Int.random(in: 5...200, using: &rng)) }
    }
    if case .timeout = script.install, chance(0.6) { script.installLandsAfter = Double(Int.random(in: 5...200, using: &rng)) }
    // A third of the steps are "late" ones: the install and the uninstall both time out and finish later.
    if chance(0.35) {
        script.install = .timeout
        script.installLandsAfter = Double(Int.random(in: 5...200, using: &rng))
        script.uninstallFailure = nil
        script.uninstallTimeoutRemoves = false
        script.uninstallLandsAfter = Double(Int.random(in: 5...200, using: &rng))
        script.snapshotFailures = []
        script.snapshotShapes = [:]
    }
    script.uninstallLeavesApp = chance(0.06)
    script.installLeavesApp = chance(0.05)
    if chance(0.03) { script.alsoAdded = ["com.example.stray": false] }
    return script
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
