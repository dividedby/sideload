import AppKit
import SideloadCore
import SwiftUI

extension MenuTone {
    var color: Color {
        switch self {
        case .plain: .primary
        case .good: .green
        case .due: .orange
        case .failed: .red
        case .neutral: .secondary
        }
    }
}

/// The 360 pt panel (design section 12; owner's round 3 layout): header, strip, Apps, doctor result, footer.
struct PanelView: View {
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            DoctorResultView(model: model)
            Divider()
            FooterView(model: model)
        }
        .padding(14)
        .frame(width: 360)
        // The window-style panel signals "opened" by becoming key; `onAppear` covers the first showing.
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reload()
        }
    }

    private var header: some View {
        HStack {
            Text("sideload").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.reload(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Check status now")
            .accessibilityLabel("Check status now")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.panel {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .failed(let issue):
            IssueView(title: "sideload could not read its state", issue: issue)
        case .firstRun(let issue):
            IssueView(title: "Welcome to sideload", issue: issue)
        case .loaded(let snapshot):
            LoadedView(snapshot: snapshot, model: model)
        }
    }
}

/// Code, message and fix, as the output contract has them.
struct IssueView: View {
    var title: String
    var issue: MenuIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.semibold)
            Text(issue.message).foregroundStyle(.secondary).font(.callout)
            if let fix = issue.fix {
                Text(fix).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            Text(issue.code).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct LoadedView: View {
    var snapshot: MenuSnapshot
    var model: MenuModel

    var body: some View {
        ActionCardView(model: model)
        StripView(strip: snapshot.strip)
        ForEach(Array(snapshot.notices.enumerated()), id: \.offset) { _, notice in
            Text("\(notice.message) \(notice.fix ?? "")")
                .font(.caption).foregroundStyle(.orange)
        }
        if snapshot.showsApps {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                if snapshot.checkingApps { ProgressView().controlSize(.mini) }
                Spacer()
                Text("signing lasts \(FreeInstallExpiry.windowDays) days").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.devices) { device in
                DeviceCardView(device: device, snapshot: snapshot, model: model)
            }
        }
        if snapshot.showsCertKitExport {
            // Exporting the cert kit changes the keychain and writes a kit, so it stays off in v1.
            Button("Export cert kit…") {}
                .disabled(true)
                .help("Export arrives later. Run `sideload export-cert` in a terminal.")
        }
    }
}

struct StripView: View {
    var strip: MenuStrip

    var body: some View {
        HStack(spacing: 4) {
            Text(strip.freeText)
            Text("·").foregroundStyle(.secondary)
            Text(strip.paidText).foregroundStyle(.secondary).font(.callout)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension View {
    /// A card on the panel's system material.
    func card() -> some View {
        padding(.horizontal, 12).padding(.vertical, 9)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}
