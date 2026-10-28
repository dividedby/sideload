import Foundation
import Testing

@testable import SideloadCore

private func result(
    _ app: String, _ status: String, code: String? = nil, before: Double? = nil, after: Double? = nil
) -> JSONValue {
    var object: [String: JSONValue] = ["app": .string(app), "status": .string(status)]
    if let code { object["code"] = .string(code) }
    if let before { object["daysLeftBefore"] = .number(before) }
    if let after { object["daysLeftAfter"] = .number(after) }
    return .object(object)
}

private func refresh(_ results: [JSONValue], errors: [Envelope.Entry] = []) -> Envelope {
    Envelope(ok: errors.isEmpty, command: "refresh", data: ["results": .array(results)], errors: errors)
}

private func entry(_ code: String, _ message: String, fix: String? = "Fix it.") -> Envelope.Entry {
    Envelope.Entry(code: code, message: message, fix: fix)
}

private let renewAll = MenuAction.renew(device: "iphone", app: nil)
private let installApollo = MenuAction.install(device: "iphone", app: "apollo")
private let removeApollo = MenuAction.remove(device: "iphone", app: "apollo")

@Suite("menu action outcome")
struct MenuActionOutcomeTests {
    @Test("refresh results map to lines: renewed with its days, renewed-not-installed, skipped by code")
    func results() {
        let envelope = refresh([
            result("stremio-ios", "renewed", before: 2, after: 7),
            result("apollo", "renewed-not-installed"),
            result("stremio-tvos", "skipped", code: "NOT_DUE"),
            result("filler", "skipped", code: "NOT_PRESENT"),
        ])
        let outcome = MenuActionOutcome(action: renewAll, envelope: envelope, cancelled: false)
        #expect(outcome.kind == .done)
        #expect(outcome.headline == "Renewed 2 apps on iphone")
        #expect(
            outcome.lines.map(\.text) == [
                "Renewed · 2 d → 7 d", "Renewed, goes back on return", "Not due", "Not on the device",
            ])
        #expect(outcome.lines.map(\.tone) == [.good, .good, .neutral, .neutral])
        #expect(outcome.lines.map(\.name) == ["Stremio", "Apollo", "Stremio", "Filler"])
        #expect(outcome.lines.allSatisfy { $0.retry == nil && $0.issue == nil })
    }

    @Test("a skip that carries a stop code says so; INTERRUPTED reads Stopped")
    func skipCodes() {
        let envelope = refresh([
            result("apollo", "skipped", code: "FREE_CERT_CHANGED"), result("filler", "skipped", code: "INTERRUPTED"),
        ])
        let outcome = MenuActionOutcome(action: renewAll, envelope: envelope, cancelled: false)
        #expect(outcome.lines.map(\.text) == ["Skipped · FREE_CERT_CHANGED", "Stopped"])
    }

    @Test("a failed app takes its issue from the error that names it, without the app prefix, and gets a Retry")
    func perAppIssue() {
        let envelope = refresh(
            [
                result("apollo", "failed", code: "DEVICE_LOCKED"), result("stremio-ios", "renewed", before: 1, after: 7),
                result("filler", "failed", code: "SIGNING_FAILED"),
            ],
            errors: [
                entry("DEVICE_LOCKED", "apollo: The device is locked.", fix: "Unlock it."),
                entry("SIGNING_FAILED", "filler: Xcode could not sign."),
            ])
        let outcome = MenuActionOutcome(action: renewAll, envelope: envelope, cancelled: false)
        #expect(outcome.kind == .failed)
        #expect(outcome.headline == "Renewed 1 of 3 on iphone")
        let apollo = outcome.lines[0]
        #expect(apollo.tone == .failed && apollo.text == "Failed · DEVICE_LOCKED")
        #expect(apollo.issue == MenuIssue(code: "DEVICE_LOCKED", message: "The device is locked.", fix: "Unlock it."))
        #expect(apollo.retry == .renew(device: "iphone", app: "apollo"))
        #expect(outcome.lines[1].retry == nil)
        #expect(outcome.lines[2].issue?.message == "Xcode could not sign.")
        #expect(outcome.issues.isEmpty)
    }

    @Test("Renewed X of Y counts the apps a fatal stop skipped, not the ones that were simply not due")
    func counts() {
        let envelope = refresh(
            [
                result("apollo", "renewed", before: 1, after: 7), result("filler", "failed", code: "FREE_CERT_CHANGED"),
                result("stremio-ios", "skipped", code: "FREE_CERT_CHANGED"), result("stremio-tvos", "skipped", code: "NOT_DUE"),
            ], errors: [entry("FREE_CERT_CHANGED", "filler: The identities changed.")])
        let outcome = MenuActionOutcome(action: renewAll, envelope: envelope, cancelled: false)
        #expect(outcome.headline == "Renewed 1 of 3 on iphone")
    }

    @Test("refresh warnings show as notes, except the lent notice the line already says")
    func warningNotes() {
        let warnings = JSONValue.array([
            ["code": "REFRESH_STATE_NOT_RECORDED", "message": "The refresh fields of apollo could not be written."],
            ["code": "APP_LENT", "message": "apollo is lent."],
        ])
        var envelope = refresh([result("apollo", "renewed", before: 1, after: 7)])
        envelope = Envelope(ok: true, command: "refresh", data: envelope.data.merging(["warnings": warnings]) { $1 })
        let outcome = MenuActionOutcome(action: renewAll, envelope: envelope, cancelled: false)
        #expect(outcome.notes == ["The refresh fields of apollo could not be written."])
    }

    @Test("a top-level error with no results is an issue, with a Retry for the whole action")
    func topLevel() {
        let envelope = Envelope.fail(
            "refresh", code: "FREE_CERT_CHANGED", message: "The free team's signing identities changed.", fix: "Check Xcode.")
        let outcome = MenuActionOutcome(action: renewAll, envelope: envelope, cancelled: false)
        #expect(outcome.kind == .failed)
        #expect(outcome.issues == [MenuIssue(code: "FREE_CERT_CHANGED", message: "The free team's signing identities changed.", fix: "Check Xcode.")])
        #expect(outcome.lines.first?.retry == renewAll)
    }

    @Test("busy: Install and Remove by the first error; Renew only when nothing renewed and every failure is busy")
    func busy() {
        let lock = Envelope.fail("install", code: "OPERATION_IN_PROGRESS", message: "Another run holds the lock.")
        for action in [installApollo, removeApollo] {
            let outcome = MenuActionOutcome(action: action, envelope: lock, cancelled: false)
            #expect(outcome.kind == .busy && outcome.headline == MenuActionOutcome.busyHeadline)
            #expect(outcome.lines.first?.retry == action && outcome.issues.isEmpty)
        }

        let full = refresh(
            [result("apollo", "failed", code: "OPERATION_IN_PROGRESS"), result("filler", "failed", code: "OPERATION_IN_PROGRESS")],
            errors: [entry("OPERATION_IN_PROGRESS", "apollo: busy"), entry("OPERATION_IN_PROGRESS", "filler: busy")])
        #expect(MenuActionOutcome(action: renewAll, envelope: full, cancelled: false).kind == .busy)

        // Partial: one app renewed, the other found the lock held. That is a failure with a per-app Retry.
        let partial = refresh(
            [result("apollo", "renewed", before: 1, after: 7), result("filler", "failed", code: "OPERATION_IN_PROGRESS")],
            errors: [entry("OPERATION_IN_PROGRESS", "filler: busy")])
        let outcome = MenuActionOutcome(action: renewAll, envelope: partial, cancelled: false)
        #expect(outcome.kind == .failed)
        #expect(outcome.lines[1].text == "Busy · try again" && outcome.lines[1].retry == .renew(device: "iphone", app: "filler"))

        // A different first error is not busy.
        let other = Envelope.fail("install", code: "DEVICE_LOCKED", message: "Locked.")
        #expect(MenuActionOutcome(action: installApollo, envelope: other, cancelled: false).kind == .failed)
    }

    @Test("cancelled is decided by the flag, not by the INTERRUPTED code")
    func cancelled() {
        let interrupted = refresh(
            [result("apollo", "failed", code: "INTERRUPTED")], errors: [entry("INTERRUPTED", "apollo: The run was interrupted.")])
        // No flag: a failure that happens to say INTERRUPTED is still a failure.
        #expect(MenuActionOutcome(action: renewAll, envelope: interrupted, cancelled: false).kind == .failed)

        // The flag with a mid-step failure that carries some other code.
        let midStep = refresh(
            [result("apollo", "renewed", before: 1, after: 7), result("filler", "failed", code: "SIGNING_FAILED")],
            errors: [entry("SIGNING_FAILED", "filler: killed")])
        let outcome = MenuActionOutcome(action: renewAll, envelope: midStep, cancelled: true)
        #expect(outcome.kind == .cancelled && outcome.headline == "Cancelled")
        #expect(outcome.issues.isEmpty)
        #expect(outcome.lines.map(\.text) == ["Renewed · 1 d → 7 d"])
        #expect(outcome.notes == ["A stopped build leaves a marker the next free command settles."])

        let stopped = Envelope.fail("app remove", code: "TIMEOUT", message: "killed")
        let remove = MenuActionOutcome(action: removeApollo, envelope: stopped, cancelled: true)
        #expect(remove.kind == .cancelled)
        #expect(
            remove.notes == [
                MenuActionOutcome.cancelNote,
                "The device may have finished; the row shows Change in progress until the window ends.",
            ])
        #expect(MenuActionOutcome(action: installApollo, envelope: stopped, cancelled: true).notes.count == 2)

        // A run that finished cleanly lost nothing.
        let fine = Envelope.result("install", [:])
        #expect(MenuActionOutcome(action: installApollo, envelope: fine, cancelled: true).kind == .done)
    }

    @Test("Remove: LAST_FREE_APP_REMOVED becomes a note; an app that was already gone says so")
    func removeNotes() {
        let warning = JSONValue.object([
            "code": "LAST_FREE_APP_REMOVED", "message": "No other free-team app is on this device, so removing apollo clears the developer trust.",
            "fix": "Trust it again.",
        ])
        let removed = Envelope.result("app remove", ["removed": true, "wasPresent": true, "warnings": .array([warning])])
        let outcome = MenuActionOutcome(action: removeApollo, envelope: removed, cancelled: false)
        #expect(outcome.kind == .done && outcome.headline == "Removed Apollo from iphone")
        #expect(outcome.notes == ["No other free-team app is on this device, so removing apollo clears the developer trust."])

        let gone = Envelope.result("app remove", ["removed": false, "wasPresent": false, "warnings": .array([])])
        let already = MenuActionOutcome(action: removeApollo, envelope: gone, cancelled: false)
        #expect(already.headline == "Apollo was already gone from iphone" && already.notes.isEmpty)
    }

    @Test("Install: INSTALL_RESULT_UNCERTAIN becomes a note on the done card")
    func installNotes() {
        let warning = CanaryCommand.warning(
            "INSTALL_RESULT_UNCERTAIN",
            "The install reported a failure (DEVICE_TIMEOUT) but the app is on the device, so it is recorded as installed.",
            "No action needed.")
        let data: [String: JSONValue] = ["app": "apollo", "installed": true, "warnings": .array([warning])]
        let outcome = MenuActionOutcome(action: installApollo, envelope: .result("install", data), cancelled: false)
        #expect(outcome.kind == .done && outcome.headline == "Installed Apollo on iphone")
        #expect(
            outcome.notes == [
                "The install reported a failure (DEVICE_TIMEOUT) but the app is on the device, so it is recorded as installed."
            ])
        let plain = MenuActionOutcome(
            action: installApollo, envelope: .result("install", ["warnings": .array([])]), cancelled: false)
        #expect(plain.notes.isEmpty)
    }

    @Test("Install and Lendable: done headlines, and a failure keeps every error with a Retry")
    func singles() {
        let ok = MenuActionOutcome(action: installApollo, envelope: .result("install", [:]), cancelled: false)
        #expect(ok.kind == .done && ok.headline == "Installed Apollo on iphone")
        let set = MenuActionOutcome(action: .lendable(device: "iphone", app: "apollo"), envelope: .result("device lendable"), cancelled: false)
        #expect(set.headline == "Apollo is lendable on iphone")
        let off = MenuActionOutcome(action: .lendable(device: "iphone", app: nil), envelope: .result("device lendable"), cancelled: false)
        #expect(off.headline == "Lending is off on iphone")

        let failed = Envelope(
            ok: false, command: "install", errors: [entry("UNTRUSTED_DEVELOPER", "Trust it.", fix: "Settings."), entry("X", "second")])
        let outcome = MenuActionOutcome(action: installApollo, envelope: failed, cancelled: false)
        #expect(outcome.kind == .failed && outcome.headline == "Install failed")
        #expect(outcome.issues.map(\.code) == ["UNTRUSTED_DEVELOPER", "X"])
        #expect(outcome.lines.first?.retry == installApollo)
    }

    @Test("everything from a command goes through the redactor")
    func redacted() {
        let udid = savedUdid("1")
        let envelope = Envelope.fail("install", code: "X", message: "device \(udid) failed", fix: "see \(udid)")
        let outcome = MenuActionOutcome(action: installApollo, envelope: envelope, cancelled: false)
        let text = (outcome.issues.map { $0.message + ($0.fix ?? "") } + outcome.lines.map(\.text)).joined()
        #expect(!text.contains(udid))
    }
}
