import SideloadCore
import SwiftUI

/// One saved device: status dot, alias, connection and free slots, the Renew… menu, then one row per app.
struct DeviceCardView: View {
    var device: MenuDeviceCard
    var snapshot: MenuSnapshot
    var model: MenuModel

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
                RenewMenu(card: device, snapshot: snapshot, model: model)
            }
            if let note = device.offlineNote ?? device.appsNote {
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.top, -4)
            }
            ForEach(Array(device.apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider() }
                AppRowView(app: app, offers: model.offers(for: app, on: device, in: snapshot), model: model)
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
            LendableLine(card: device, snapshot: snapshot, model: model)
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

/// "Renew… ▾": All apps plus each app. Choosing one opens the inline confirm; a disabled item says why in its label and in
/// its help text.
struct RenewMenu: View {
    var card: MenuDeviceCard
    var snapshot: MenuSnapshot
    var model: MenuModel

    var body: some View {
        Menu {
            ForEach(card.renew.items, id: \.title) { item in
                let action = MenuAction.renew(device: card.alias, app: item.app)
                let availability = model.availability(action, in: snapshot)
                Button {
                    model.request(action)
                } label: {
                    Text(label(item, availability))
                }
                .disabled(!availability.isEnabled)
                .help(availability.reason ?? "")
            }
        } label: {
            Text("Renew…")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!model.controlsEnabled)
    }

    private func label(_ item: MenuRenewMenu.Item, _ availability: MenuAvailability) -> String {
        let base = item.detail.map { "\(item.title)  \($0)" } ?? (item.due ? "\(item.title)  due" : item.title)
        return availability.reason.map { "\(base)  ·  \($0)" } ?? base
    }
}

/// "Lendable: Apollo" and the menu that changes it. A setting only: it says which app the lab may borrow the slot of.
struct LendableLine: View {
    var card: MenuDeviceCard
    var snapshot: MenuSnapshot
    var model: MenuModel

    var body: some View {
        let choices: [String?] = MenuActions.lendableChoices(card) + [nil]
        if choices.count > 1 {
            HStack {
                Text("Lendable: \(card.lendableApp.map(MenuActions.displayName) ?? "none")")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Change…") {
                    ForEach(choices, id: \.self) { app in
                        let action = MenuAction.lendable(device: card.alias, app: app)
                        let availability = model.availability(action, in: snapshot)
                        Button(app.map(MenuActions.displayName) ?? "None") { model.request(action) }
                            .disabled(!availability.isEnabled)
                            .help(availability.reason ?? "")
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.small)
                .disabled(!model.controlsEnabled)
            }
        }
    }
}

struct AppRowView: View {
    var app: MenuAppRow
    var offers: [MenuOffer]
    var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(app.name)
                Spacer()
                Text(app.daysLabel)
                    .foregroundStyle(app.textTone.color)
                    .fontWeight(app.showsBar && app.level != .ok ? .semibold : .regular)
                let others = offers.filter { $0.kind != .retry }
                if !others.isEmpty {
                    Menu {
                        ForEach(others, id: \.action) { offer in
                            Button(offer.label, role: offer.destructive ? .destructive : nil) { model.request(offer.action) }
                                .disabled(!offer.availability.isEnabled)
                                .help(offer.availability.reason ?? "")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(app.name)")
                }
            }
            if app.showsBar {
                TimeLeftBar(fraction: app.barFraction, tone: app.barTone)
            }
            if let failure = app.failure {
                HStack {
                    Text(failure).font(.callout).foregroundStyle(MenuTone.failed.color)
                    Spacer()
                    if let retry = offers.first(where: { $0.kind == .retry }) {
                        Button("Retry") { model.request(retry.action) }
                            .buttonStyle(.link)
                            .disabled(!retry.availability.isEnabled)
                            .help(retry.availability.reason ?? "")
                    }
                }
            }
            if let exception = app.exception {
                Text(exception).font(.callout).foregroundStyle(.secondary)
            }
        }
        // Grouped, not combined: the row's buttons and menu stay reachable on their own.
        .accessibilityElement(children: .contain)
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
