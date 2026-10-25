import Foundation
import Testing

@testable import SideloadCore

// The slot state machine's outcome table (docs/design.md section 18), one row per case, like ProvisionRenewMatrixTests.
// Each case seeds a ledger and a simulated device, runs one command, and asserts the record's state, the ok/code, the
// freed count, the warnings and the exact devicectl calls. The invariant (below) is checked after every case against the
// true state of the simulated device.

private let infoApps = "device info apps"
private let uninstallApp = "device uninstall app"
private let installApp = "device install app"

/// A legacy `lent[]` record, as an earlier build wrote it. A pending one carries an `opAt` well in the past, so its window is
/// over (one with no `opAt` is the fail-safe case, tested in `SlotMigrationTests`).
private func record(_ state: String, app: String = "stremio-ios", to: String = "lab") -> LedgerLent {
    LedgerLent(app: app, device: "iphone", to: to, since: daysFromNow(-1), state: state, opAt: state == "lent" ? nil : daysFromNow(-1))
}

enum SlotRow: String, CaseIterable, Sendable {
    case L0, L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, L11
    case T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10
    case M1, M2, M3, M4, M5
    case I1, I2, I3, I4
    case G1, G2, G3, G4
}

struct RowCase: Sendable {
    var label: String
    var command: SlotCommandKind
    var script = DeviceScript()
    var lendable: String? = "stremio-ios"
    var lent: LedgerLent?
    /// Unified records seeded directly (after the legacy fields, which are migrated first).
    var slots: [LedgerSlot] = []
    var installs: [LedgerInstall] = [installRecord(.stremioIOS)]
    var signed = true
    var profileDays = 5.0
    var keychain: [[KeychainCertificate]?]?
    var marker: LedgerFreeInFlight?
    var crashAt: String?
    /// The row is a gate row: the ledger must be byte-for-byte what it was seeded as.
    var gated = false

    var state: SlotPhase = .none
    var installPresent: Bool?
    var ok = false
    var code: String?
    var freed: Int?
    var warnings: [String] = []
    var calls: [String] = []
    var fields: [String: JSONValue] = [:]
    var check: (@Sendable (JSONValue) -> Bool)?
}

private func deviceHolding(_ ids: [String: Bool]) -> DeviceScript { DeviceScript(initial: ids) }

private func cases(_ row: SlotRow) throws -> [RowCase] {
    let locked = try loadFixtureJSON("install-locked.json")
    let limit = try loadFixtureJSON("install-free-app-limit.json")
    let only: [String: Bool] = [stremioId: true]
    let withWda: [String: Bool] = [stremioId: true, wdaId: true]
    var c = RowCase(label: "", command: .lend)
    func lend(_ label: String, _ build: (inout RowCase) -> Void) -> RowCase {
        var x = c
        x.label = label
        x.command = .lend
        build(&x)
        return x
    }
    func back(_ label: String, _ build: (inout RowCase) -> Void) -> RowCase {
        var x = c
        x.label = label
        x.command = .giveBack
        x.installs = [installRecord(.stremioIOS, present: false)]
        build(&x)
        return x
    }
    func remove(_ label: String, _ build: (inout RowCase) -> Void) -> RowCase {
        var x = c
        x.label = label
        x.command = .remove
        build(&x)
        return x
    }
    func plain(_ label: String, _ build: (inout RowCase) -> Void) -> RowCase {
        var x = c
        x.label = label
        x.command = .install
        build(&x)
        return x
    }
    let three = [infoApps, uninstallApp, infoApps]
    let reinstall3 = [infoApps, installApp, infoApps]
    c.label = row.rawValue

    switch row {
    // MARK: lend
    case .L0:
        return [
            lend("lent to the lab already") {
                $0.lent = record("lent")
                $0.state = .lent
                $0.ok = true
                $0.freed = 0
                $0.fields = ["alreadyLent": true]
            },
            lend("settleInFlight comes before even the lent answer") {
                $0.lent = record("lent")
                $0.keychain = [nil]
                $0.state = .lent
                $0.code = "KEYCHAIN_LOCKED"
            },
        ]
    case .L1:
        return [
            lend("another app is lent") {
                $0.lent = record("lent", app: "apollo")
                $0.state = .lent
                $0.code = "ALREADY_LENT"
            },
            lend("lent to someone else") {
                $0.lent = record("lent", to: "someone")
                $0.state = .lent
                $0.code = "ALREADY_LENT"
            },
        ]
    case .L2:
        return [
            lend("no record, S0 fails") {
                $0.script = DeviceScript(initial: only, snapshotFailures: [1])
                $0.code = "SNAPSHOT_FAILED"
                $0.calls = [infoApps]
                $0.installPresent = true
            },
            lend("lending, S0 fails") {
                $0.script = DeviceScript(initial: only, snapshotFailures: [1])
                $0.lent = record("lending")
                $0.state = .lending
                $0.code = "SLOT_STATE_UNKNOWN"
                $0.freed = 0
                $0.fields = ["uncertain": true, "state": "lending", "cause": "SNAPSHOT_FAILED"]
                $0.calls = [infoApps]
            },
            lend("returning, S0 fails") {
                $0.script = DeviceScript(snapshotFailures: [1])
                $0.lent = record("returning")
                $0.state = .returning
                $0.code = "SLOT_STATE_UNKNOWN"
                $0.fields = ["uncertain": true, "state": "returning"]
                $0.calls = [infoApps]
            },
        ]
    case .L3:
        return [
            lend("lending, the app is gone") {
                $0.lent = record("lending")
                $0.state = .lent
                $0.ok = true
                $0.freed = 1
                $0.warnings = ["UNINSTALL_RESULT_UNCERTAIN"]
                $0.installPresent = false
                $0.calls = [infoApps]
            },
            lend("returning, the app is not back") {
                $0.lent = record("returning")
                $0.state = .lent
                $0.ok = true
                $0.freed = 0
                $0.fields = ["alreadyLent": true]
                $0.warnings = ["RETURN_NOT_LANDED"]
                $0.installPresent = false
                $0.calls = [infoApps]
            },
        ]
    case .L4:
        return [
            lend("lending, the app is there: the old uninstall did not land, so lend afresh") {
                $0.script = deviceHolding(withWda)
                $0.lent = record("lending")
                $0.state = .lent
                $0.ok = true
                $0.freed = 1
                $0.installPresent = false
                $0.calls = three
            },
            lend("returning, the app is there") {
                $0.script = deviceHolding(withWda)
                $0.lent = record("returning")
                $0.state = .lent
                $0.ok = true
                $0.freed = 1
                $0.calls = three
            },
        ]
    case .L5:
        return [
            lend("nothing recorded and the app is not installed") {
                $0.script = deviceHolding([wdaId: true])
                $0.code = "LENDABLE_NOT_INSTALLED"
                $0.installPresent = false
                $0.calls = [infoApps]
            }
        ]
    case .L6:
        return [
            lend("nothing signed") {
                $0.script = deviceHolding(only)
                $0.signed = false
                $0.code = "NOT_SIGNED"
                $0.installPresent = true
                $0.calls = [infoApps]
            },
            lend("profile expired") {
                $0.script = deviceHolding(only)
                $0.profileDays = -1
                $0.code = "PROFILE_EXPIRED"
                $0.installPresent = true
                $0.calls = [infoApps]
            },
            lend("a pending record is settled before the signed check") {
                $0.script = deviceHolding(only)
                $0.signed = false
                $0.lent = record("lending")
                $0.code = "NOT_SIGNED"
                $0.state = .none
                $0.installPresent = true
                $0.calls = [infoApps]
            },
        ]
    case .L7:
        return [
            lend("a crash right after the intent: lending, the app untouched") {
                $0.script = deviceHolding(only)
                $0.crashAt = "lend.intent"
                $0.state = .lending
                $0.installPresent = true
                $0.calls = [infoApps]
            }
        ]
    case .L8:
        return [
            lend("the uninstall worked") {
                $0.script = deviceHolding(only)
                $0.state = .lent
                $0.ok = true
                $0.freed = 1
                $0.warnings = ["LAST_FREE_APP_REMOVED"]
                $0.installPresent = false
                $0.calls = three
            },
            lend("the uninstall timed out but the app is gone") {
                $0.script = DeviceScript(initial: withWda, uninstallTimeoutRemoves: true)
                $0.state = .lent
                $0.ok = true
                $0.freed = 1
                $0.warnings = ["UNINSTALL_RESULT_UNCERTAIN"]
                $0.installPresent = false
                $0.calls = three
            },
            lend("the uninstall failed but the app is gone") {
                $0.script = DeviceScript(initial: withWda, uninstallFailure: locked, uninstallFailureRemoves: true)
                $0.state = .lent
                $0.ok = true
                $0.freed = 1
                $0.warnings = ["UNINSTALL_RESULT_UNCERTAIN"]
                $0.calls = three
            },
            lend("another app vanished too: lent is written first, then UNEXPECTED_APP_DELTA") {
                $0.script = DeviceScript(initial: [stremioId: true, "com.example.other": false], alsoRemovedOnUninstall: ["com.example.other"])
                $0.state = .lent
                $0.code = "UNEXPECTED_APP_DELTA"
                $0.freed = 1
                $0.fields = ["state": "lent"]
                $0.installPresent = false
                $0.calls = three
            },
        ]
    case .L9:
        return [
            lend("the uninstall reported success but the app is listed: kept pending, nothing claimed") {
                $0.script = DeviceScript(initial: withWda, uninstallLeavesApp: true)
                $0.state = .lending
                $0.code = "UNEXPECTED_APP_DELTA"
                $0.freed = 0
                $0.fields = ["uninstalled": false, "uncertain": true, "state": "lending"]
                $0.installPresent = true
                $0.calls = three
            },
            lend("the uninstall failed and the app is listed") {
                $0.script = DeviceScript(initial: withWda, uninstallFailure: locked)
                $0.state = .none
                $0.code = "DEVICE_LOCKED"
                $0.freed = 0
                $0.installPresent = true
                $0.calls = three
            },
        ]
    case .L10:
        return [
            lend("a timeout with the app still listed proves nothing") {
                $0.script = DeviceScript(initial: withWda, uninstallTimeoutRemoves: false)
                $0.state = .lending
                $0.code = "TIMEOUT"
                $0.freed = 0
                $0.fields = ["uncertain": true, "state": "lending"]
                $0.installPresent = true
                $0.calls = three
            }
        ]
    case .L11:
        return [
            lend("success, then S1 fails") {
                $0.script = DeviceScript(initial: only, snapshotFailures: [2])
                $0.state = .lending
                $0.code = "UNINSTALL_RESULT_UNCERTAIN"
                $0.freed = 0
                $0.fields = ["uncertain": true, "state": "lending"]
                $0.calls = three
            },
            lend("timeout, then S1 fails") {
                $0.script = DeviceScript(initial: only, snapshotFailures: [2], uninstallTimeoutRemoves: true)
                $0.state = .lending
                $0.code = "TIMEOUT"
                $0.freed = 0
                $0.fields = ["uncertain": true, "state": "lending"]
                $0.calls = three
            },
        ]

    // MARK: return
    case .T0:
        return [
            back("nothing lent") {
                $0.ok = true
                $0.fields = ["nothingLent": true, "reinstalled": false]
            }
        ]
    case .T1:
        return [
            back("keychain locked") {
                $0.lent = record("lent")
                $0.keychain = [nil]
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "KEYCHAIN_LOCKED", "state": "lent", "lent": true]
            },
            back("keychain locked, nothing lent") {
                $0.keychain = [nil]
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "KEYCHAIN_LOCKED", "state": "none", "lent": false]
            },
            back("identities changed during an unfinished run") {
                $0.lent = record("returning")
                $0.marker = LedgerFreeInFlight(beforeFp8: ["00000000"], startedAt: testNow, app: "stremio-ios", device: "iphone")
                $0.state = .returning
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "FREE_CERT_CHANGED", "state": "returning", "lent": true]
            },
        ]
    case .T2:
        return [
            back("lent, S0 fails") {
                $0.script = DeviceScript(snapshotFailures: [1])
                $0.lent = record("lent")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "SNAPSHOT_FAILED", "state": "lent", "lent": true]
                $0.calls = [infoApps]
            },
            back("returning, S0 fails") {
                $0.script = DeviceScript(snapshotFailures: [1])
                $0.lent = record("returning")
                $0.state = .returning
                $0.code = "RETURN_FAILED"
                $0.fields = ["state": "returning", "uncertain": true]
                $0.calls = [infoApps]
            },
        ]
    case .T3:
        return [
            back("returning, the app is there: settled") {
                $0.script = deviceHolding(only)
                $0.lent = record("returning")
                $0.ok = true
                $0.fields = ["reinstalled": true, "settled": true]
                $0.installPresent = true
                $0.calls = [infoApps]
            },
            back("lent, the app is there already") {
                $0.script = deviceHolding(only)
                $0.lent = record("lent")
                $0.ok = true
                $0.fields = ["reinstalled": false, "alreadyPresent": true]
                $0.installPresent = true
                $0.calls = [infoApps]
            },
        ]
    case .T4:
        return [
            back("lending, the app is gone: recorded lent before the checks") {
                $0.signed = false
                $0.lent = record("lending")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "NOT_SIGNED", "state": "lent"]
                $0.installPresent = false
                $0.calls = [infoApps]
            }
        ]
    case .T5:
        return [
            back("nothing signed") {
                $0.signed = false
                $0.lent = record("lent")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "NOT_SIGNED", "lent": true, "state": "lent"]
                $0.calls = [infoApps]
            },
            back("profile expired") {
                $0.profileDays = -1
                $0.lent = record("lent")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "PROFILE_EXPIRED", "state": "lent"]
                $0.calls = [infoApps]
            },
            back("the slot was taken meanwhile") {
                $0.script = deviceHolding([apolloId: true, wdaId: true, sideStoreId: true])
                $0.lent = record("lent")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "FREE_APP_LIMIT", "state": "lent"]
                $0.calls = [infoApps]
            },
        ]
    case .T6:
        return [
            back("a crash right after the returning intent") {
                $0.lent = record("lent")
                $0.crashAt = "return.intent"
                $0.state = .returning
                $0.calls = [infoApps]
            }
        ]
    case .T7:
        return [
            back("the install worked") {
                $0.lent = record("lent")
                $0.ok = true
                $0.fields = ["reinstalled": true]
                $0.installPresent = true
                $0.calls = reinstall3
            },
            back("the install failed but landed") {
                $0.script = DeviceScript(install: .fail(json: locked), landsDespiteFailure: true)
                $0.lent = record("lending")
                $0.ok = true
                $0.warnings = ["INSTALL_RESULT_UNCERTAIN"]
                $0.installPresent = true
                $0.calls = reinstall3
            },
            back("the install timed out but landed") {
                $0.script = DeviceScript(install: .timeoutLanding)
                $0.lent = record("lent")
                $0.ok = true
                $0.warnings = ["INSTALL_RESULT_UNCERTAIN"]
                $0.installPresent = true
                $0.calls = reinstall3
            },
            back("another app landed too: the return is recorded first, then UNEXPECTED_APP_DELTA") {
                $0.script = DeviceScript(alsoAdded: ["com.example.stray": false])
                $0.lent = record("lent")
                $0.state = .none
                $0.code = "UNEXPECTED_APP_DELTA"
                $0.fields = ["returned": true, "lent": false]
                $0.installPresent = true
                $0.calls = reinstall3
            },
        ]
    case .T8:
        return [
            back("success claimed, the app is not listed: kept pending, the slot is not free") {
                $0.script = DeviceScript(installLeavesApp: true)
                $0.lent = record("lent")
                $0.state = .returning
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "INSTALL_UNCONFIRMED", "lent": true, "state": "returning", "uncertain": true]
                $0.installPresent = true
                $0.calls = reinstall3
            },
            back("the install failed, the app is not listed") {
                $0.script = DeviceScript(install: .fail(json: locked))
                $0.lent = record("returning")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "DEVICE_LOCKED", "state": "lent"]
                $0.calls = reinstall3
            },
            back("installd's slots-full failure") {
                $0.script = DeviceScript(install: .fail(json: limit))
                $0.lent = record("lent")
                $0.state = .lent
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "FREE_APP_LIMIT", "state": "lent"]
                $0.check = { $0["installdList"] != nil }
                $0.calls = reinstall3
            },
        ]
    case .T9:
        return [
            back("the install timed out and the app is not listed (yet)") {
                $0.script = DeviceScript(install: .timeout)
                $0.lent = record("lent")
                $0.state = .returning
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "TIMEOUT", "uncertain": true, "state": "returning", "lent": true]
                $0.calls = reinstall3
            }
        ]
    case .T10:
        return [
            back("success, then S1 fails") {
                $0.script = DeviceScript(snapshotFailures: [2])
                $0.lent = record("lent")
                $0.state = .returning
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "SNAPSHOT_FAILED", "uncertain": true, "state": "returning", "lent": true]
                $0.calls = reinstall3
            },
            back("failure, then S1 fails") {
                $0.script = DeviceScript(snapshotFailures: [2], install: .fail(json: locked))
                $0.lent = record("lent")
                $0.state = .returning
                $0.code = "RETURN_FAILED"
                $0.fields = ["cause": "DEVICE_LOCKED", "uncertain": true, "state": "returning"]
                $0.calls = reinstall3
            },
        ]

    // MARK: app remove
    case .M1:
        return [
            remove("S0 fails") {
                $0.script = DeviceScript(initial: only, snapshotFailures: [1])
                $0.lent = record("lending")
                $0.state = .lending
                $0.code = "SNAPSHOT_FAILED"
                $0.installPresent = true
                $0.calls = [infoApps]
            }
        ]
    case .M2:
        return [
            remove("lending, the app is gone") {
                $0.lent = record("lending")
                $0.state = .lent
                $0.ok = true
                $0.fields = ["removed": false]
                $0.installPresent = false
                $0.calls = [infoApps]
            },
            remove("lent: nothing to remove") {
                $0.lent = record("lent")
                $0.state = .lent
                $0.ok = true
                $0.fields = ["removed": false]
                $0.calls = [infoApps]
            },
            remove("no record, not on the device") {
                $0.ok = true
                $0.fields = ["removed": false, "wasPresent": false]
                $0.installPresent = false
                $0.calls = [infoApps]
            },
        ]
    case .M3:
        return [
            remove("removed") {
                $0.script = deviceHolding(withWda)
                $0.ok = true
                $0.fields = ["removed": true]
                $0.installPresent = false
                $0.calls = three
            },
            remove("timeout, the app is gone") {
                $0.script = DeviceScript(initial: withWda, uninstallTimeoutRemoves: true)
                $0.ok = true
                $0.warnings = ["UNINSTALL_RESULT_UNCERTAIN"]
                $0.installPresent = false
                $0.calls = three
            },
            remove("another app vanished too") {
                $0.script = DeviceScript(initial: [stremioId: true, "com.example.other": false], alsoRemovedOnUninstall: ["com.example.other"])
                $0.code = "UNEXPECTED_APP_DELTA"
                $0.installPresent = false
                $0.calls = three
            },
        ]
    case .M4:
        return [
            remove("success claimed, the app is listed: kept pending") {
                $0.script = DeviceScript(initial: withWda, uninstallLeavesApp: true)
                $0.code = "UNEXPECTED_APP_DELTA"
                $0.fields = ["uninstalled": false, "uncertain": true]
                $0.installPresent = true
                $0.calls = three
            },
            remove("the uninstall failed") {
                $0.script = DeviceScript(initial: withWda, uninstallFailure: locked)
                $0.code = "DEVICE_LOCKED"
                $0.installPresent = true
                $0.calls = three
            },
            remove("a timeout, the app is listed") {
                $0.script = DeviceScript(initial: withWda, uninstallTimeoutRemoves: false)
                $0.code = "TIMEOUT"
                $0.installPresent = true
                $0.calls = three
            },
        ]
    case .M5:
        return [
            remove("S1 fails: present, not removed") {
                $0.script = DeviceScript(initial: withWda, snapshotFailures: [2])
                $0.installs = [installRecord(.stremioIOS, present: false)]
                $0.code = "UNINSTALL_RESULT_UNCERTAIN"
                $0.fields = ["uncertain": true]
                $0.installPresent = true
                $0.calls = three
            },
            remove("a timeout, then S1 fails") {
                $0.script = DeviceScript(initial: withWda, snapshotFailures: [2], uninstallTimeoutRemoves: true)
                $0.code = "TIMEOUT"
                $0.fields = ["uncertain": true]
                $0.installPresent = true
                $0.calls = three
            },
        ]

    // MARK: plain install
    case .I1:
        return [
            plain("a failed install that landed is recorded present, uncertain") {
                $0.script = DeviceScript(install: .fail(json: locked), landsDespiteFailure: true)
                $0.installs = [installRecord(.stremioIOS, present: false)]
                $0.ok = true
                $0.warnings = ["INSTALL_RESULT_UNCERTAIN"]
                $0.installPresent = true
                $0.calls = reinstall3
            }
        ]
    case .I2:
        return [
            plain("a failed install that did not land: the failure stands") {
                $0.script = DeviceScript(install: .fail(json: locked))
                $0.installs = []
                $0.code = "DEVICE_LOCKED"
                $0.calls = reinstall3
            },
            plain("a timeout with no evidence reads present, never free") {
                $0.script = DeviceScript(install: .timeout)
                $0.installs = [installRecord(.stremioIOS, present: false)]
                $0.code = "TIMEOUT"
                $0.installPresent = true
                $0.calls = reinstall3
            },
        ]
    case .I3:
        return [
            plain("success, then S1 fails: kept pending, reads present, nothing claimed") {
                $0.script = DeviceScript(snapshotFailures: [2])
                $0.installs = []
                $0.code = "SNAPSHOT_FAILED"
                $0.fields = ["uncertain": true, "pending": true]
                $0.installPresent = true
                $0.calls = reinstall3
            }
        ]
    case .I4:
        return [
            plain("a pending record for another app is settled by the install's snapshot, and then counts as lent") {
                $0.lent = record("lending", app: "apollo")
                $0.installs = []
                $0.state = .lent
                $0.ok = true
                $0.check = { $0["slots"]?["lent"] == 1 }
                $0.calls = reinstall3
            }
        ]

    // MARK: the gate: any op in flight on the device answers SLOT_PENDING, with no device call, for every command
    case .G1:
        return pendingCases("a pending plain install of another app") { $0.slots = [pendingSlot("apollo", .install, by: .install)] }
    case .G2:
        return pendingCases("a pending reinstall of this app") { $0.slots = [pendingSlot("stremio-ios", .reinstall, by: .install)] }
    case .G3:
        return pendingCases("a pending remove") { $0.slots = [pendingSlot("stremio-ios", .uninstall, by: .remove)] }
    case .G4:
        return pendingCases("a pending lend") {
            $0.slots = [pendingSlot("stremio-ios", .uninstall, by: .lend, lentTo: "lab")]
            $0.installs = []
        }
    }
}

/// An op that started a minute before `testNow` (inside every window).
private func pendingSlot(_ app: String, _ kind: LedgerSlotKind, by: LedgerSlotBy, lentTo: String? = nil) -> LedgerSlot {
    LedgerSlot(
        device: "iphone", app: app, presence: .present, lentTo: lentTo, since: lentTo == nil ? nil : testNow.addingTimeInterval(-60),
        op: LedgerSlotOp(kind: kind, by: by, startedAt: testNow.addingTimeInterval(-60), window: SlotRule.window(kind)))
}

/// The same pending record, asked by each of the four mutating commands: SLOT_PENDING, `freed:0`, no device call, no change.
private func pendingCases(_ label: String, _ seed: (inout RowCase) -> Void) -> [RowCase] {
    [SlotCommandKind.lend, .giveBack, .remove, .install].map { command in
        var x = RowCase(label: "\(label), asked by \(command)", command: command)
        x.installs = []
        x.lent = nil
        seed(&x)
        x.script = DeviceScript(initial: [stremioId: true, apolloId: true])
        x.code = "SLOT_PENDING"
        x.freed = nil
        x.fields = ["uncertain": true]
        x.check = { $0["retryAfter"] != nil && $0["op"] != nil && $0["state"] != nil }
        x.calls = []
        x.gated = true
        return x
    }
}

@Suite("slot model: the outcome table")
struct SlotMatrixTests {
    @Test("every row of the outcome table", arguments: SlotRow.allCases)
    func row(_ row: SlotRow) async throws {
        for c in try cases(row) {
            try await run(c, row: row)
        }
    }

    private func run(_ c: RowCase, row: SlotRow) async throws {
        let name = "\(row.rawValue) \(c.label)"
        try await withInstallWorld(
            script: c.script, lendable: c.lendable, signed: c.signed, profileDays: c.profileDays, keychain: c.keychain,
            ledger: { ledger in
                ledger.installs = c.installs
                if let seed = c.lent { ledger.lent = [seed] }
                ledger.slots = c.slots
                if !c.slots.isEmpty { SlotRule.project(&ledger) }
                ledger.freeProvisionInFlight = c.marker
            }
        ) { w in
            let before = try w.ledger()
            let out = await runSlotCommand(c.command, w, crashAt: c.crashAt)
            let printed = json(out)
            #expect(out.ok == c.ok, "\(name): ok=\(out.ok) \(out.errors)")
            if c.gated {
                #expect(try w.ledger().slots == before.slots && w.ledger().lent == before.lent, "\(name): the gate changed the ledger")
            }
            if let code = c.code { #expect(out.errorCodes == [code], "\(name): \(out.errorCodes)") }
            if let freed = c.freed { #expect(printed["freed"] == .number(Double(freed)), "\(name): freed \(String(describing: printed["freed"]))") }
            if !c.gated {
                #expect(
                    SlotPhase(w.lent.first { $0.device == "iphone" }) == c.state,
                    "\(name): state \(String(describing: w.lent.first?.state))")
            }
            if c.ok {
                let codes = printed["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
                #expect(codes == c.warnings, "\(name): warnings \(codes)")
            }
            for (key, value) in c.fields { #expect(printed[key] == value, "\(name): \(key) = \(String(describing: printed[key]))") }
            if let present = c.installPresent {
                #expect(w.installs.first { $0.id == w.key }?.present == present, "\(name): installs present")
            }
            if let check = c.check { #expect(check(printed), "\(name): check") }
            #expect(w.runner.deviceCalls == c.calls, "\(name): calls \(w.runner.deviceCalls)")
            try expectSlotModel(w, label: name)
            try expectSlotModel(w, label: name, eventually: true)
            try w.expectClean(out)
        }
    }

    @Test("a pending state is never answered from the ledger: only lent short-circuits, with no device call")
    func onlyLentShortCircuits() async throws {
        for state in ["lending", "returning"] {
            try await withInstallWorld(script: DeviceScript(initial: [stremioId: true]), lendable: "stremio-ios", ledger: { $0.lent = [record(state)] }) { w in
                let out = await w.slot("lend", device: "iphone", to: "lab")
                #expect(!w.runner.deviceCalls.isEmpty, "\(state) was answered without asking the device")
                #expect(json(out)["alreadyLent"] == nil || out.ok)
            }
        }
    }

    @Test("every invalid snapshot shape is a failed read, never an empty device", arguments: SnapshotFault.allCases)
    func malformedSnapshots(_ fault: SnapshotFault) async throws {
        // S0 invalid: the record is left as it is.
        for state in ["lending", "returning", "lent"] {
            let seeded = record(state)
            try await withInstallWorld(script: DeviceScript(snapshotShapes: [1: fault]), ledger: { $0.lent = [seeded] }) { w in
                let back = await w.slot("return", device: "iphone")
                #expect(back.errorCodes == ["RETURN_FAILED"])
                #expect(w.lent == [seeded], "\(fault) \(state)")
                #expect(w.runner.deviceCalls == [infoApps])
            }
        }
        // S1 invalid after an uninstall: nothing is claimed.
        try await withInstallWorld(
            script: DeviceScript(initial: [stremioId: true], snapshotShapes: [2: fault]), lendable: "stremio-ios"
        ) { w in
            let out = await w.slot("lend", device: "iphone", to: "lab")
            #expect(!out.ok && json(out)["freed"] == 0)
            #expect(w.lent.map(\.state) == ["lending"], "\(fault)")
        }
        // S1 invalid after an install: the return is not claimed.
        try await withInstallWorld(script: DeviceScript(snapshotShapes: [2: fault]), lendable: "stremio-ios", ledger: { $0.lent = [record("lent")] }) { w in
            #expect(await w.slot("return", device: "iphone").errorCodes == ["RETURN_FAILED"])
            #expect(w.lent.map(\.state) == ["returning"], "\(fault)")
        }
    }

    @Test("AppSnapshot.parse accepts only a complete listing")
    func parseShapes() {
        for fault in SnapshotFault.allCases { #expect(AppSnapshot.parse(fault.json) == nil, "\(fault)") }
        #expect(AppSnapshot.parse(nil) == nil)
        let empty: JSONValue = ["info": ["outcome": "success"], "result": ["apps": []]]
        #expect(AppSnapshot.parse(empty)?.ids == [])
        #expect(AppSnapshot.parse(appsJSON([stremioId: true]))?.ids == [stremioId])
        // IDs come only from result.apps elements: one nested elsewhere is not read.
        let nested: JSONValue = ["info": ["outcome": "success"], "result": ["apps": [], "other": [["bundleIdentifier": "x.y"]]]]
        #expect(AppSnapshot.parse(nested)?.ids == [])
    }
}
