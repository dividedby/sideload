import Foundation

// What the action card says when a menu action ended (design section 12): the command's one envelope, read into lines
// and issues. Pure; every text that came from a command goes through `MenuIssue`, which redacts it.

/// One app's line in the result: "Stremio · Renewed · 2 d → 7 d".
public struct MenuResultLine: Sendable, Equatable, Identifiable {
    public var id: String { app }
    /// The app key; empty for a line about the whole action.
    public var app: String
    public var name: String
    public var tone: MenuTone
    public var text: String
    /// Code, message and fix of a failure on this line.
    public var issue: MenuIssue?
    /// Offered on a failed or busy line; it goes through the inline confirm again.
    public var retry: MenuAction?
}

public struct MenuActionOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case done, failed, busy, cancelled
    }

    public var kind: Kind
    public var headline: String
    public var lines: [MenuResultLine]
    /// Failures that belong to no app line (the command stopped before it began).
    public var issues: [MenuIssue]
    public var notes: [String]

    public static let busyHeadline = "Busy — another sideload or lab run is signing. Try again."
    static let cancelNote = "A stopped build leaves a marker the next free command settles."
    static let deviceNote = "The device may have finished; the row shows Change in progress until the window ends."

    /// - Parameter cancelled: the menu's Cancel was used. The model's flag decides, not the `INTERRUPTED` code: `refresh`
    ///   looks at the task only between apps, so a cancel in the middle of a step comes back as that step's failure.
    public init(action: MenuAction, envelope: Envelope, cancelled: Bool) {
        let alias = action.device
        kind = .done
        headline = ""
        lines = []
        issues = []
        notes = []
        switch action {
        case .renew(_, let app): readRenew(app, alias: alias, envelope: envelope, action: action)
        case .install(_, let app):
            let name = MenuFormat.appName(app)
            readSingle(envelope, action: action, app: app, done: "Installed \(name) on \(alias)", failed: "Install failed")
        case .remove(_, let app):
            let name = MenuFormat.appName(app)
            let gone = envelope.data["wasPresent"] == .bool(false)
            readSingle(
                envelope, action: action, app: app,
                done: gone ? "\(name) was already gone from \(alias)" : "Removed \(name) from \(alias)", failed: "Remove failed")
            if envelope.ok { notes += Self.warningNotes(envelope) }
        case .lendable(_, let app):
            let name = app.map(MenuFormat.appName)
            readSingle(
                envelope, action: action, app: app ?? "",
                done: name.map { "\($0) is lendable on \(alias)" } ?? "Lending is off on \(alias)", failed: "Setting not saved")
        }
        // A run that finished cleanly despite the click lost nothing, so it is reported as done.
        if cancelled, !envelope.ok {
            kind = .cancelled
            headline = "Cancelled"
            issues = []
            notes = [Self.cancelNote]
            switch action {
            case .install, .remove: notes.append(Self.deviceNote)
            default: break
            }
            // What finished before the stop stays visible; what was cut short is not a failure to retry.
            lines = lines.filter { $0.tone == .good }
        }
    }

    // MARK: refresh

    private mutating func readRenew(_ app: String?, alias: String, envelope: Envelope, action: MenuAction) {
        let results = Self.results(envelope)
        let errors = envelope.errors
        let renewedCount = results.filter { ["renewed", "renewed-not-installed"].contains($0.status) }.count
        if renewedCount == 0, !errors.isEmpty, errors.allSatisfy({ $0.code == "OPERATION_IN_PROGRESS" }) {
            becomeBusy(action)
            return
        }
        var claimed = Set<Int>()
        for result in results {
            let key = result.app
            let name = MenuFormat.appName(key)
            switch result.status {
            case "renewed":
                lines.append(line(key, name, .good, "Renewed" + Self.span(result)))
            case "renewed-not-installed":
                lines.append(line(key, name, .good, "Renewed, goes back on return"))
            case "skipped":
                lines.append(line(key, name, .neutral, Self.skipText(result.code)))
            default:
                // A failed app takes its message from the error entry that names it ("<app>: ...").
                var issue: MenuIssue?
                if let index = errors.indices.first(where: { !claimed.contains($0) && errors[$0].message.hasPrefix("\(key): ") }) {
                    claimed.insert(index)
                    let entry = errors[index]
                    issue = MenuIssue(code: entry.code, message: String(entry.message.dropFirst(key.count + 2)), fix: entry.fix)
                }
                let code = issue?.code ?? result.code ?? "INTERNAL_ERROR"
                issue = issue ?? MenuIssue(code: code, message: "The renewal did not finish.")
                if code == "INTERRUPTED" {
                    lines.append(line(key, name, .neutral, "Stopped", retry: .renew(device: alias, app: key)))
                } else if code == "OPERATION_IN_PROGRESS" {
                    lines.append(line(key, name, .neutral, "Busy · try again", retry: .renew(device: alias, app: key)))
                } else {
                    lines.append(
                        line(key, name, .failed, "Failed · \(code)", issue: issue, retry: .renew(device: alias, app: key)))
                }
            }
        }
        // Errors no app line took (the run stopped before any app, or a stop that names no app).
        for (index, entry) in errors.enumerated() where !claimed.contains(index) {
            if results.isEmpty || entry.code != "INTERRUPTED" {
                issues.append(MenuIssue(code: entry.code, message: entry.message, fix: entry.fix))
            }
        }
        if results.isEmpty, !envelope.ok { lines.append(line("", "", .neutral, "Not run", retry: action)) }

        let failed = results.filter { $0.status == "failed" }.count
        if envelope.ok {
            kind = .done
            let target = app.map(MenuFormat.appName) ?? "all apps"
            headline =
                renewedCount == 0
                ? "Nothing needed renewing on \(alias)"
                : renewedCount == 1 && app != nil ? "Renewed \(target) on \(alias)" : "Renewed \(renewedCount) app\(renewedCount == 1 ? "" : "s") on \(alias)"
        } else {
            kind = .failed
            headline =
                renewedCount > 0
                ? "Renewed \(renewedCount) of \(renewedCount + max(failed, 1)) on \(alias)"
                : "Renewal failed on \(alias)"
        }
    }

    private struct RefreshResult {
        var app: String
        var status: String
        var code: String?
        var before: Int?
        var after: Int?
    }

    private static func results(_ envelope: Envelope) -> [RefreshResult] {
        guard case .array(let items)? = envelope.data["results"] else { return [] }
        var results: [RefreshResult] = []
        for case .object(let item) in items {
            guard case .string(let app)? = item["app"], case .string(let status)? = item["status"] else { continue }
            var result = RefreshResult(app: app, status: status)
            if case .string(let code)? = item["code"] { result.code = code }
            if case .number(let n)? = item["daysLeftBefore"] { result.before = Int(n) }
            if case .number(let n)? = item["daysLeftAfter"] { result.after = Int(n) }
            results.append(result)
        }
        return results
    }

    /// " · 2 d → 7 d" when both numbers are known.
    private static func span(_ result: RefreshResult) -> String {
        guard let before = result.before, let after = result.after else { return "" }
        return " · \(before) d → \(after) d"
    }

    private static func skipText(_ code: String?) -> String {
        switch code {
        case "NOT_DUE": "Not due"
        case "NOT_PRESENT", "NOT_INSTALLED": "Not on the device"
        case "NOT_SIGNED": "No signed build"
        case "INTERRUPTED": "Stopped"
        case let code?: "Skipped · \(code)"
        case nil: "Skipped"
        }
    }

    // MARK: install, remove, lendable

    private mutating func readSingle(_ envelope: Envelope, action: MenuAction, app: String, done: String, failed: String) {
        if envelope.ok {
            kind = .done
            headline = done
            return
        }
        if envelope.errors.first?.code == "OPERATION_IN_PROGRESS" {
            becomeBusy(action)
            return
        }
        kind = .failed
        headline = failed
        issues = envelope.errors.map { MenuIssue(code: $0.code, message: $0.message, fix: $0.fix) }
        lines = [line(app, app.isEmpty ? "" : MenuFormat.appName(app), .failed, "Not completed", retry: action)]
    }

    private static func warningNotes(_ envelope: Envelope) -> [String] {
        guard case .array(let warnings)? = envelope.data["warnings"] else { return [] }
        var notes: [String] = []
        for case .object(let warning) in warnings {
            guard case .string(let message)? = warning["message"] else { continue }
            notes.append(MenuIssue(code: "", message: message).message)
        }
        return notes
    }

    // MARK: shared

    private mutating func becomeBusy(_ action: MenuAction) {
        kind = .busy
        headline = Self.busyHeadline
        issues = []
        lines = [line("", "", .neutral, "Not run", retry: action)]
    }

    private func line(
        _ app: String, _ name: String, _ tone: MenuTone, _ text: String, issue: MenuIssue? = nil, retry: MenuAction? = nil
    ) -> MenuResultLine {
        MenuResultLine(app: app, name: name, tone: tone, text: text, issue: issue, retry: retry)
    }
}

/// The action card's states (design section 12). Nothing runs in `confirming`; the owner's click on the confirm button is
/// the command's `--yes`.
public enum MenuActionState: Sendable, Equatable {
    case idle
    case confirming(MenuAction, MenuPrompt)
    /// `cancelling` is set once Cancel was pressed and the command has not returned yet.
    case running(label: String, cancellable: Bool, cancelling: Bool)
    case finished(MenuActionOutcome)
}
