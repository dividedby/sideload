import SideloadCore
import SwiftUI

/// "Add device…", under the panel's content. Opening it only lists devices.
struct AddDeviceRow: View {
    var model: MenuModel

    var body: some View {
        HStack {
            Button("Add device…") { model.openAddDevice() }
                .buttonStyle(.plain)
                .disabled(!model.canAddDevice)
                .help("Save a device paired with this Mac")
            Spacer(minLength: 0)
        }
    }
}

/// Add device's card: pick a device that is not saved, give it an alias, then Continue opens the confirm. Nothing is saved here.
struct DevicePickerView: View {
    var picker: MenuDevicePicker
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add device").fontWeight(.semibold)
            switch picker {
            case .looking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").foregroundStyle(.secondary)
                }
                buttons { EmptyView() }
            case .failed(let issue):
                Text(issue.message).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                if let fix = issue.fix {
                    Text(fix).font(.callout).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
                Text(issue.code).font(.caption2).foregroundStyle(.tertiary)
                buttons { checkAgain }
            case .list(let candidates) where candidates.isEmpty:
                Text(MenuAddDevice.noneFound).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                buttons { checkAgain }
            case .list(let candidates):
                DeviceChoiceForm(candidates: candidates, model: model).id(candidates)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var checkAgain: some View {
        Button("Check again") { model.findDevices() }
    }

    private func buttons(@ViewBuilder _ extra: () -> some View) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { model.dismiss() }
            extra()
        }
        .padding(.top, 2)
    }
}

private struct DeviceChoiceForm: View {
    var candidates: [MenuDeviceCandidate]
    var model: MenuModel
    @State private var chosen: MenuDeviceCandidate?
    @State private var alias: String

    init(candidates: [MenuDeviceCandidate], model: MenuModel) {
        self.candidates = candidates
        self.model = model
        let first = MenuAddDevice.preselected(candidates)
        _chosen = State(initialValue: first)
        _alias = State(initialValue: first?.suggestedAlias ?? "")
    }

    private var problem: String? { MenuAddDevice.aliasProblem(alias, taken: model.savedAliases) }

    var body: some View {
        ForEach(candidates) { candidate in
            Button {
                chosen = candidate
                alias = candidate.suggestedAlias
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: chosen == candidate ? "largecircle.fill.circle" : "circle")
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title)
                        if let blocked = candidate.blocked {
                            Text(blocked).font(.caption).foregroundStyle(.secondary).fixedSize(
                                horizontal: false, vertical: true)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(candidate.blocked != nil)
        }
        if chosen != nil {
            TextField("Alias", text: $alias)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Alias")
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("Cancel") { model.dismiss() }
            if let chosen {
                Button("Continue…") { model.chooseDevice(chosen, alias: alias) }
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
            } else {
                Button("Check again") { model.findDevices() }
            }
        }
        .padding(.top, 2)
    }
}
