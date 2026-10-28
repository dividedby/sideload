import SideloadCore
import SwiftUI

/// One saved device: status dot, alias, connection and free slots, the Renew… menu, then one row per app.
struct DeviceCardView: View {
    var device: MenuDeviceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    StatusDot(filled: device.dotFilled)
                    Text(device.alias).fontWeight(.semibold)
                }
                Spacer(minLength: 8)
                Text("\(device.connectionLabel) · \(device.slotsLabel)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                RenewMenu(renew: device.renew)
            }
            if let note = device.offlineNote ?? device.appsNote {
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.top, -4)
            }
            ForEach(Array(device.apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider() }
                AppRowView(app: app)
            }
            ForEach(device.reservedSlots, id: \.self) { title in
                if !device.apps.isEmpty || title != device.reservedSlots.first { Divider() }
                HStack {
                    Text(title)
                    Spacer()
                    Text("not managed by sideload").font(.callout)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct StatusDot: View {
    var filled: Bool

    var body: some View {
        Group {
            if filled {
                Circle().fill(.green)
            } else {
                Circle().strokeBorder(.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityLabel(filled ? "visible" : "not visible")
    }
}

/// "Renew… ▾": All apps plus each app. Disabled because the menu does not call `refresh` yet; the items are shown so the
/// final shape is visible.
struct RenewMenu: View {
    var renew: MenuRenewMenu

    var body: some View {
        Menu {
            ForEach(renew.items, id: \.title) { item in
                Button {
                    // Unreachable while the menu is disabled. Every real action will go through the inline confirm.
                } label: {
                    Text(item.detail.map { "\(item.title)  \($0)" } ?? (item.due ? "\(item.title)  due" : item.title))
                }
            }
        } label: {
            Text("Renew…")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!renew.enabled)
        .help(renew.tooltip ?? "")
    }
}

struct AppRowView: View {
    var app: MenuAppRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(app.name)
                Spacer()
                Text(app.daysLabel)
                    .foregroundStyle(app.textTone.color)
                    .fontWeight(app.showsBar && app.level != .ok ? .semibold : .regular)
            }
            if app.showsBar {
                TimeLeftBar(fraction: app.barFraction, tone: app.barTone)
            }
            if let failure = app.failure {
                Text(failure).font(.callout).foregroundStyle(MenuTone.failed.color)
            }
            if let exception = app.exception {
                Text(exception).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Time left over the 7-day window: green in the good zone, orange when due.
struct TimeLeftBar: View {
    var fraction: Double
    var tone: MenuTone

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(tone.color).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}
