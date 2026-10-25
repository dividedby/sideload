import AppKit
import SideloadCore
import SwiftUI

/// Run doctor, Settings…, Open ~/.sideload, Quit. Nothing here mutates sideload's state.
struct FooterView: View {
    var model: MenuModel

    var body: some View {
        HStack(spacing: 2) {
            Button("Run doctor") { model.runDoctor() }
                .disabled(model.doctor == .running)
            // v1 Settings opens config.json in the default editor; it is disabled until the file exists.
            Button("Settings…") { NSWorkspace.shared.open(URL(fileURLWithPath: model.configPath)) }
                .disabled(!FileManager.default.fileExists(atPath: model.configPath))
                .help("Open config.json in your default editor")
            Button("Open ~/.sideload") {
                NSWorkspace.shared.open(URL(fileURLWithPath: model.homePath, isDirectory: true))
            }
            .disabled(!FileManager.default.fileExists(atPath: model.homePath))
            Spacer(minLength: 0)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -2)
    }
}

/// The result of Run doctor, inline.
struct DoctorResultView: View {
    var model: MenuModel

    var body: some View {
        switch model.doctor {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Running doctor…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelDoctor() }.buttonStyle(.link)
            }
        case .done(let summary):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summary.ok ? "Doctor: all checks passed" : "Doctor: needs attention").fontWeight(.semibold)
                    Spacer()
                    Button("Hide") { model.dismissDoctor() }.buttonStyle(.link)
                }
                ForEach(summary.rows) { row in
                    DoctorRowView(row: row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

struct DoctorRowView: View {
    var row: DoctorSummary.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let fix = row.fix, row.severity == .warn || row.severity == .fail {
                    Text(fix).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var symbol: String {
        switch row.severity {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .info: "info.circle"
        }
    }

    private var color: Color {
        switch row.severity {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .info: .secondary
        }
    }
}
