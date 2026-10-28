import SideloadCore
import SwiftUI

/// The card at the top of the loaded panel (design section 12): the inline confirm, the running state, and the result.
/// Nothing runs until the confirm button is clicked; that click is the owner's `--yes`.
struct ActionCardView: View {
    var model: MenuModel

    var body: some View {
        switch model.actionState {
        case .idle:
            EmptyView()
        case .confirming(_, let prompt):
            ConfirmView(prompt: prompt, model: model)
        case .running(let label, let cancellable, let cancelling):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(cancelling ? "Cancelling…" : label).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if cancellable {
                    Button("Cancel") { model.cancelAction() }
                        .buttonStyle(.link)
                        .disabled(cancelling)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        case .finished(let outcome):
            ResultView(outcome: outcome, model: model)
        }
    }
}

private struct ConfirmView: View {
    var prompt: MenuPrompt
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.title).fontWeight(.semibold)
            ForEach(Array(prompt.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                Button(prompt.confirmLabel, role: prompt.destructive ? .destructive : nil) { model.confirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(prompt.destructive ? .red : .accentColor)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct ResultView: View {
    var outcome: MenuActionOutcome
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol).foregroundStyle(tone.resultColor).frame(width: 14)
                Text(outcome.headline).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { model.dismiss() }.buttonStyle(.link)
            }
            ForEach(outcome.lines) { line in
                LineView(line: line, model: model)
            }
            ForEach(Array(outcome.issues.enumerated()), id: \.offset) { _, issue in
                IssueText(issue: issue)
            }
            ForEach(Array(outcome.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var symbol: String {
        switch outcome.kind {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .busy: "clock"
        case .cancelled: "minus.circle"
        }
    }

    private var tone: MenuTone {
        switch outcome.kind {
        case .done: .good
        case .failed: .failed
        case .busy, .cancelled: .neutral
        }
    }
}

private struct LineView: View {
    var line: MenuResultLine
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                if !line.name.isEmpty { Text(line.name) }
                Text(line.text).foregroundStyle(line.tone.resultColor)
                Spacer()
                if let retry = line.retry {
                    let availability = model.retryAvailability(retry)
                    Button("Retry") { model.request(retry) }
                        .buttonStyle(.link)
                        .disabled(!availability.isEnabled)
                        .help(availability.reason ?? "")
                }
            }
            .font(.callout)
            if let issue = line.issue { IssueText(issue: issue) }
        }
    }
}

extension MenuTone {
    /// Colour marks only what is due or failed: a success in a result card is plain text.
    var resultColor: Color { self == .good ? MenuTone.plain.color : color }
}

/// Code, message and fix, small.
private struct IssueText: View {
    var issue: MenuIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let fix = issue.fix {
                Text(fix).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(issue.code).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
