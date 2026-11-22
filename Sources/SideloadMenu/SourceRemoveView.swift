import SideloadCore
import SwiftUI

/// Remove source's card (design section 12): the owner's sources to pick from. Nothing is removed here; Continue ends at the
/// inline confirm, which is where the owner's click is the `--yes`.
struct SourceRemoveView: View {
    var picker: MenuSourceRemovePicker
    var model: MenuModel
    @State private var chosen: MenuRemovableSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MenuSourceRemove.cardTitle).fontWeight(.semibold)
            switch picker {
            case .failed(let issue):
                IssueText(issue: issue)
                buttons(continuing: false)
            case .choosing(let listed, _) where listed.isEmpty:
                Text(MenuSourceRemove.noneAdded).secondaryNote()
                buttons(continuing: false)
            case .choosing(let listed, let problem):
                Text(MenuSourceRemove.pickerIntro).secondaryNote()
                ForEach(listed) { source in
                    Button {
                        chosen = source
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(
                                systemName: chosen == source ? "largecircle.fill.circle" : "circle"
                            )
                            .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                Text(source.detail).secondaryNote(.caption)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if let problem { IssueText(issue: problem) }
                buttons(continuing: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func buttons(continuing: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { model.dismiss() }
            if continuing {
                Button("Continue…") {
                    if let chosen { model.chooseSourceToRemove(chosen) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen == nil)
            }
        }
        .padding(.top, 2)
    }
}

private struct IssueText: View {
    var issue: MenuIssue

    var body: some View {
        Text(issue.message).secondaryNote()
        if let fix = issue.fix {
            Text(fix).secondaryNote(.caption)
        }
        Text(issue.code).font(.caption2).foregroundStyle(.tertiary)
    }
}
