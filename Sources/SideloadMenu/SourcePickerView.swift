import SideloadCore
import SwiftUI

/// Add source's card (design section 12): the address field, the read, and the list of an index's apps. Nothing is written
/// here; Continue ends at the inline confirm, which is where the owner's click is the `--yes`.
struct SourcePickerView: View {
    var picker: MenuSourcePicker
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MenuSourceAdd.cardTitle).fontWeight(.semibold)
            switch picker {
            case .entering(let url, let problem):
                SourceAddressForm(url: url, problem: problem, model: model)
            case .looking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(MenuSourceAdd.readingLabel).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.dismiss() }
                }
                .padding(.top, 2)
            case .choosing(let choices):
                SourceChoiceForm(choices: choices, model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct SourceAddressForm: View {
    var problem: MenuIssue?
    var model: MenuModel
    @State private var url: String

    init(url: String, problem: MenuIssue?, model: MenuModel) {
        self.problem = problem
        self.model = model
        _url = State(initialValue: url)
    }

    private var invalid: String? { url.isEmpty ? nil : MenuSourceAdd.urlProblem(url) }

    var body: some View {
        Text(MenuSourceAdd.addressHint).secondaryNote()
        TextField(MenuSourceAdd.addressPlaceholder, text: $url)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Source address")
            .onSubmit { model.previewSource(url: url) }
        if let invalid {
            Text(invalid).secondaryNote(.caption)
        }
        if let problem {
            Text(problem.message).secondaryNote()
            if let fix = problem.fix {
                Text(fix).secondaryNote(.caption)
            }
            Text(problem.code).font(.caption2).foregroundStyle(.tertiary)
        }
        HStack {
            Spacer()
            Button("Cancel") { model.dismiss() }
            Button("Continue…") { model.previewSource(url: url) }
                .buttonStyle(.borderedProminent)
                .disabled(MenuSourceAdd.urlProblem(url) != nil)
        }
        .padding(.top, 2)
    }
}

private struct SourceChoiceForm: View {
    var choices: MenuSourceChoices
    var model: MenuModel
    @State private var chosen: MenuSourceChoice?

    var body: some View {
        Text(choices.intro).secondaryNote()
        ForEach(choices.choices) { choice in
            Button {
                chosen = choice
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: chosen == choice ? "largecircle.fill.circle" : "circle")
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title)
                        if let blocked = choice.blocked {
                            Text(blocked).secondaryNote(.caption)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(choice.blocked != nil)
        }
        if choices.truncated {
            Text(choices.truncatedNote).secondaryNote(.caption)
        }
        HStack {
            Spacer()
            Button("Cancel") { model.dismiss() }
            Button("Continue…") {
                if let chosen { model.chooseSource(choices, chosen) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen == nil)
        }
        .padding(.top, 2)
    }
}

extension View {
    /// Small grey text that wraps instead of being cut: a hint, a reason or a note on a card.
    func secondaryNote(_ font: Font = .callout) -> some View {
        self.font(font).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
