import Foundation

/// What `devicectl list devices` has told us so far.
public enum DeviceProbe: Sendable, Equatable {
    /// Not answered yet: cards say "checking…".
    case checking
    /// `devicectl` failed: visibility is unknown, which is never shown as offline.
    case failed
    case listed([ListedDevice])
}

/// Everything the snapshot is built from. Plain values: no file, process or clock is touched.
public struct MenuInputs: Sendable {
    public var now: Date
    /// The last canary run's status (nil when there is none).
    public var canaryStatus: String?
    public var config: Config
    public var ledger: Ledger
    public var probe: DeviceProbe
    public var notices: [MenuIssue]
    /// False when `ledger.json` could not be read: `ledger` is then empty and says nothing about the slots.
    public var ledgerReadable: Bool
    /// Whether `refresh` exists. False in v1: auto-renew state is then not shown at all (no per-row exception, no
    /// "renews when back" wording). When it ships, the app sets this true and the exception renders.
    public var autoRefreshAvailable: Bool
    /// A renewal started from the menu is running.
    public var renewing: Bool
    /// A renewal failed: OR-ed with what the builder derives from the installs' last refresh result.
    public var renewFailed: Bool
    /// What the live app list of each visible device showed; a missing key means the device was not asked.
    public var deviceApps: [String: DeviceAppsProbe]

    public init(
        now: Date, canaryStatus: String?, config: Config, ledger: Ledger, probe: DeviceProbe,
        notices: [MenuIssue] = [], ledgerReadable: Bool = true, autoRefreshAvailable: Bool = false, renewing: Bool = false,
        renewFailed: Bool = false, deviceApps: [String: DeviceAppsProbe] = [:]
    ) {
        self.ledgerReadable = ledgerReadable
        self.renewing = renewing
        self.renewFailed = renewFailed
        self.autoRefreshAvailable = autoRefreshAvailable
        self.deviceApps = deviceApps
        self.now = now
        self.canaryStatus = canaryStatus
        self.config = config
        self.ledger = ledger
        self.probe = probe
        self.notices = notices
    }
}

/// Pure: inputs in, `MenuSnapshot` out (design sections 12 and 18).
public enum MenuSnapshotBuilder {
    /// The free team allows 3 apps per device (design section 18).
    public static let slotLimit = 3

    /// One card with the expiry items of the rows that are in the ring.
    private struct DeviceBuild {
        var card: MenuDeviceCard
        var expiring: [ExpiryItem] = []
        var renewFailed = false
    }

    public static func build(_ inputs: MenuInputs) -> MenuSnapshot {
        let now = inputs.now
        let config = inputs.config
        let ledger = inputs.ledger

        // The slot records and `installs[]` as `status` reads them: migrated and projected in memory.
        let projected = SlotRule.migrated(ledger, now: now)
        let built = config.devices.keys
            .sorted { lhs, rhs in
                let l = (config.devices[lhs]?.platform == "tvos" ? 1 : 0, lhs)
                let r = (config.devices[rhs]?.platform == "tvos" ? 1 : 0, rhs)
                return l < r
            }
            .compactMap { alias in
                config.devices[alias].map { device(alias: alias, saved: $0, inputs: inputs, projected: projected) }
            }
        let cards = built.map(\.card)

        // The paid-side state: paid certificate/profile expiry, plus one item per free install on a device, through the
        // same worst-state rule `status` uses (expiry outranks `blocked`; an expired item is `critical`).
        var items = ExpiryItems.compute(ledger, now: now)
        let expiring = built.flatMap(\.expiring)
        items += expiring
        let soonest = expiring.map(\.notAfter).min()
        let state = StatusState.worst(canaryStatus: inputs.canaryStatus, items: items)
        let paid = PaidAccountState(canaryStatus: inputs.canaryStatus)
        // The ring follows the soonest free install; the paid state matters only when there is none.
        let icon = MenuIcon.make(
            soonest: soonest, now: now, paid: state, certChanged: ledger.freeSuspended != nil,
            renewing: inputs.renewing, renewFailed: inputs.renewFailed || built.contains { $0.renewFailed })
        let checkingApps = config.devices.contains { alias, saved in
            presence(of: saved, probe: inputs.probe).isVisible && inputs.deviceApps[alias] == .checking
        }

        return MenuSnapshot(
            generated: now, state: state, icon: icon,
            strip: MenuStrip(
                freeInUse: !ledger.freeSigned.isEmpty || !ledger.freeProfiles.isEmpty || !ledger.installs.isEmpty, paid: paid),
            devices: cards, showsApps: cards.contains { !$0.apps.isEmpty }, showsCertKitExport: paid != .blocked,
            checkingDevices: inputs.probe == .checking, checkingApps: checkingApps, notices: inputs.notices,
            ledgerReadable: inputs.ledgerReadable, appIds: appIds(inputs), suspended: ledger.freeSuspended != nil)
    }

    private static func appIds(_ inputs: MenuInputs) -> MenuAppIds? {
        guard inputs.ledgerReadable, let reserved = try? inputs.config.freeTeamReservedAppIds() else { return nil }
        return MenuAppIds(recent: FreeAppIdBudget.live(inputs.ledger.freeAppIds, now: inputs.now).count, reserved: reserved)
    }

    /// The expiry of a hand-installed app: the signed app's embedded profile. When `provision` has since stored a profile
    /// with the same UUID its record says the same; a different UUID is a newer profile that is not installed yet, so it
    /// does not move the date. Never used for an app that has an `installs[]` record: `sign` advances `freeSigned` before
    /// `install` puts the build on the device.
    static func expiry(of signed: LedgerFreeSigned, in ledger: Ledger) -> Date {
        let same = ledger.freeProfiles.first { $0.id == signed.id && $0.profileUuid == signed.profileUuid }
        return same?.expires ?? signed.profileExpires
    }

    static func presence(of saved: SavedDevice, probe: DeviceProbe) -> MenuPresence {
        switch probe {
        case .checking: return .checking
        case .failed: return .unknown
        case .listed(let devices):
            let listed = DeviceList.findSaved(devices, matching: saved)
            if DeviceList.visibilityOf(listed) == .ok, let listed { return .visible(listed.transport) }
            return .offline(lastSeen: listed?.lastConnection)
        }
    }

    /// One app on one device before it becomes a row.
    private struct Candidate {
        let app: String
        let bundleId: String?
        var install: LedgerInstall?
        var slot: LedgerSlot?
        /// Set only for a hand-installed app: signed by sideload, put on the device by something else.
        var signed: LedgerFreeSigned?
    }

    /// The record's own ID, else the one the prefix and the app name give.
    private static func bundleId(of app: String, recorded: String?, prefix: String?) -> String? {
        recorded ?? ProvisionApp(rawValue: app)?.freeBundleId(prefix: prefix)
    }

    /// Whether a snapshot taken at `takenAt` can say anything about this record: not when the ledger has learned something
    /// since (a lend that completed, an install `refresh` confirmed), which a cached read from before it would contradict.
    private static func usable(_ slot: LedgerSlot, takenAt: Date) -> Bool {
        takenAt >= (slot.seenAt ?? .distantPast) && takenAt >= (slot.since ?? .distantPast)
    }

    private static func device(alias: String, saved: SavedDevice, inputs: MenuInputs, projected: Ledger) -> DeviceBuild {
        let now = inputs.now
        let ledger = inputs.ledger
        let prefix = inputs.config.bundleIdPrefix
        let presence = presence(of: saved, probe: inputs.probe)
        var offline = false
        if case .offline = presence { offline = true }
        var listChecking = false
        if case .checking = presence { listChecking = true }

        // What the device itself said, only while it is visible: a read of a device that has since gone away says nothing.
        let probe = presence.isVisible ? inputs.deviceApps[alias] : nil
        let read = probe?.appsRead
        var failedCode: String?
        var reading = listChecking
        switch probe {
        case .failed(let code, _)?: failedCode = code
        case .checking?: reading = true
        default: break
        }

        let slots = projected.slots.filter { $0.device == alias }
        let candidates = gather(alias: alias, ledger: ledger, projected: projected, slots: slots, prefix: prefix, read: read)

        var rows: [MenuAppRow] = []
        var expiring: [ExpiryItem] = []
        var renewItems: [MenuRenewMenu.Item] = []
        var renewFailed = false
        for candidate in candidates.sorted(by: { ($0.app, $0.install?.id ?? "") < ($1.app, $1.install?.id ?? "") }) {
            let state = classify(candidate, alias: alias, read: read, reading: reading)
            let live = state.isLive
            let expires = candidate.install?.profileExpires ?? candidate.signed.map { expiry(of: $0, in: ledger) }
            let signedBuild = ledger.freeSigned.first { $0.id == "\(alias)/\(candidate.app)" }
            // In the ring, the strip and the Renew items: what is, or may be, on the device and has a date. A pending
            // row needs an install date (an `installs[]` record); an app that is not installed or is lent has no countdown.
            let dated = live ? expires : nil

            // A failed last renewal, from the install's own record (`refresh --auto` and the manual `refresh` write it);
            // `skipped` and `renewed-not-installed` are not failures. Only a code of the plain shape is shown.
            var failure: String?
            if live, let refresh = candidate.install?.refresh, refresh.lastResult == "failed" {
                var text = "Renewal failed"
                if let code = refresh.lastCode, code.wholeMatch(of: /[A-Z0-9_]+/) != nil { text += " · " + code }
                failure = text
                renewFailed = true
            }
            // Auto-renew shows only as an exception, once refresh exists. An offline device says its state once on the card.
            let exception = inputs.autoRefreshAvailable && !offline && !saved.autoRefresh && dated != nil ? "Auto-renew off" : nil
            var built = row(candidate, state: state, alias: alias, expires: dated, failure: failure, exception: exception, now: now)
            built.expires = dated
            built.recorded = candidate.install != nil
            built.signedExpires = signedBuild?.profileExpires
            if let install = candidate.install, let signedBuild {
                // A different profile that outlives the installed one by more than a day, and is not expired itself.
                built.newerSigned =
                    signedBuild.profileUuid != install.profileUuid
                    && signedBuild.profileExpires > install.profileExpires.addingTimeInterval(FreeInstallExpiry.secondsPerDay)
                    && signedBuild.profileExpires > now
            }
            if state == .installed, let read, let id = candidate.bundleId {
                built.removalClearsTrust = FreeRemoval.isLastFreeApp(bundleId: id, in: read.snapshot, prefix: prefix)
            }
            rows.append(built)
            if let dated {
                let item =
                    candidate.install.map { ExpiryItems.item($0, now: now) }
                    ?? ExpiryItem(
                        kind: .install, name: "\(candidate.app) @ \(alias)", notAfter: dated, daysLeft: built.daysLeft,
                        level: built.level)
                expiring.append(item)
                renewItems.append(MenuRenewMenu.Item(title: built.name, detail: nil, due: built.level != .ok, app: candidate.app))
            } else if state == .lent, let signedBuild {
                // A lent app is renewed without the device (provision and sign; `slot return` puts the copy back).
                let level = FreeInstallExpiry.assess(expires: signedBuild.profileExpires, now: now).level
                renewItems.append(MenuRenewMenu.Item(title: built.name, detail: nil, due: level != .ok, app: candidate.app))
            }
        }

        // An out-of-range stored reserve (a hand-edited config) says nothing about the slots, like an unreadable ledger.
        let known = inputs.ledgerReadable && saved.freeSlotsReserved != nil
        let reserved = saved.freeSlotsReserved ?? 0
        // Unknown slots: none is shown free.
        let free =
            known
            ? freeSlots(
                alias: alias, ledger: ledger, projected: projected, slots: slots, reserved: reserved, prefix: prefix, read: read)
            : 0
        let reservedRows = (0..<reserved).map { n in reserved == 1 ? "Reserved slot" : "Reserved slot (\(n + 1))" }

        let card = MenuDeviceCard(
            alias: alias, presence: presence, connectionLabel: MenuFormat.connection(presence), freeSlots: free,
            slotsLabel: known ? MenuFormat.slots(free) : "slots unknown",
            offlineNote: offlineNote(presence, saved: saved, autoRefreshAvailable: inputs.autoRefreshAvailable, now: now),
            appsNote: appsNote(failedCode: failedCode, rows: rows, readOverRows: read != nil, presence: presence),
            apps: rows, reservedSlots: reservedRows,
            renew: MenuRenewMenu(
                items: [MenuRenewMenu.Item(title: "All apps", detail: "\(renewItems.count)", due: false, app: nil)] + renewItems),
            platform: saved.platform, slotsKnown: known, lendableApp: saved.lendableApp,
            hasPending: rows.contains { $0.presence == .pending }, liveRead: liveRead(presence: presence, probe: probe))
        return DeviceBuild(card: card, expiring: expiring, renewFailed: renewFailed)
    }

    private static func liveRead(presence: MenuPresence, probe: DeviceAppsProbe?) -> MenuLiveRead {
        guard presence.isVisible else { return .none }
        switch probe {
        case .read?: return .read
        case .failed?: return .failed
        case .checking?: return .checking
        case nil: return .none
        }
    }

    /// The rows of a device: what `install` recorded as present (the slot record decides presence, not `freeSigned`, which
    /// `sign` advances before `install`), what is lent or has an operation in flight, and signed apps the device shows that
    /// sideload did not install.
    private static func gather(
        alias: String, ledger: Ledger, projected: Ledger, slots: [LedgerSlot], prefix: String?, read: AppsRead?
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for install in ExpiryItems.presentInstalls(projected, devices: [alias]) {
            candidates.append(
                Candidate(
                    app: install.app, bundleId: install.bundleId, install: install,
                    slot: slots.first { $0.app == install.app }))
        }
        for slot in slots where (slot.lentTo != nil || slot.op != nil) && !candidates.contains(where: { $0.app == slot.app }) {
            let install = projected.installs.first { $0.id == slot.id }
            candidates.append(
                Candidate(
                    app: slot.app, bundleId: bundleId(of: slot.app, recorded: install?.bundleId, prefix: prefix), install: install,
                    slot: slot))
        }
        if let read {
            for signed in ledger.freeSigned where signed.device == alias && read.shows(signed.bundleId) {
                if candidates.contains(where: { $0.app == signed.app || $0.bundleId == signed.bundleId }) { continue }
                // A slot record (an absent one after `app remove`) is newer than a read taken before it was written.
                let slot = slots.first { $0.app == signed.app }
                if let slot, !usable(slot, takenAt: read.takenAt) { continue }
                candidates.append(Candidate(app: signed.app, bundleId: signed.bundleId, slot: slot, signed: signed))
            }
        }
        return candidates
    }

    /// The one line an offline device shows ("Seen 3 h ago"); nil for any other.
    private static func offlineNote(_ presence: MenuPresence, saved: SavedDevice, autoRefreshAvailable: Bool, now: Date) -> String? {
        guard case .offline(let lastSeen) = presence else { return nil }
        let seen = lastSeen.map { "Seen " + MenuFormat.ago(from: $0, now: now) } ?? "Offline"
        if autoRefreshAvailable {
            return seen + " · " + (saved.autoRefresh ? "renews when back on Wi-Fi or USB" : "auto-renew off")
        }
        // The card header already says "offline"; the state is shown once. Never seen: no line at all.
        return lastSeen == nil ? nil : seen
    }

    /// A visible device whose list could not be read says so once, for the whole card; its rows show the ledger's record.
    /// The same for a read the ledger has overtaken (ignored: a row it was meant to settle shows the record unconfirmed) and
    /// for a device list that failed. `readOverRows` is whether a live read exists to have been overtaken.
    private static func appsNote(failedCode: String?, rows: [MenuAppRow], readOverRows: Bool, presence: MenuPresence) -> String? {
        if let failedCode {
            let why =
                switch failedCode {
                case "DEVICE_LOCKED": "device locked"
                case "TIMEOUT": "timed out"
                default: "couldn't read"
                }
            return "Couldn't check apps (\(why)) · showing last known"
        }
        let overtaken = readOverRows && rows.contains { $0.presence == .unconfirmed }
        if !rows.isEmpty, overtaken || presence == .unknown { return "Couldn't check apps · showing last known" }
        return nil
    }

    /// Where the app is, first match wins. A live read settles the record in memory (`SlotRule.settle`, the rule `install`
    /// writes): an operation past its window resolves from the snapshot, one inside it stays pending, a lent app that is
    /// back on the device is no longer lent. Without a read, the ledger alone speaks.
    private static func classify(_ candidate: Candidate, alias: String, read: AppsRead?, reading: Bool) -> AppPresence {
        let slot = candidate.slot ?? LedgerSlot(device: alias, app: candidate.app, presence: .unknown)
        if let read, let id = candidate.bundleId, usable(slot, takenAt: read.takenAt) {
            let present = read.shows(id)
            let settled = SlotRule.settle(slot, present: present, takenAt: read.takenAt)
            if settled.op != nil { return .pending }
            if settled.lentTo != nil { return .lent }
            return present ? .installed : .notInstalled
        }
        // A change in progress comes before lent: only a lent slot with nothing in flight is the lab's to hold.
        if slot.op != nil { return .pending }
        if slot.lentTo != nil { return .lent }
        return reading ? .checking : .unconfirmed
    }

    private static func row(
        _ candidate: Candidate, state: AppPresence, alias: String, expires: Date?, failure: String?, exception: String?,
        now: Date
    ) -> MenuAppRow {
        var days = 0
        var level = ExpiryItem.Level.ok
        if let expires { (days, level) = FreeInstallExpiry.assess(expires: expires, now: now) }
        var row = MenuAppRow(
            id: "\(alias)/\(candidate.app)", app: candidate.app, name: MenuFormat.appName(candidate.app), presence: state,
            daysLeft: days, level: level, daysLabel: "", barFraction: 0, barTone: .neutral, textTone: .neutral, showsBar: false,
            exception: exception, failure: failure, expires: nil, recorded: candidate.install != nil, signedExpires: nil,
            newerSigned: false, removalClearsTrust: false)
        switch state {
        case .installed, .unconfirmed:
            guard let expires else {
                row.daysLabel = "Installed"
                return row
            }
            row.daysLabel = FreeInstallExpiry.label(expires: expires, now: now)
            row.barFraction = FreeInstallExpiry.barFraction(expires: expires, now: now)
            row.barTone = FreeInstallExpiry.barTone(level)
            row.textTone = FreeInstallExpiry.textTone(level)
            row.showsBar = true
        case .notInstalled: row.daysLabel = "Signed · not installed"
        case .lent: row.daysLabel = "Lent to lab"
        case .pending: row.daysLabel = "Change in progress"
        case .checking: row.daysLabel = "checking…"
        }
        return row
    }

    /// Free slots on a device. With a live read this is what `install` computes without a profile read: the snapshot's
    /// managed apps, the owner's reserve, and the records the snapshot does not show (a lent slot, an operation that may
    /// still land). Without one, the ledger alone: the slot records, plus a signed app that has no slot record at all (a
    /// slot record, even an absent one, is newer than `freeSigned` and decides). Either way a pending or lent slot is
    /// never free.
    private static func freeSlots(
        alias: String, ledger: Ledger, projected: Ledger, slots: [LedgerSlot], reserved: Int, prefix: String?, read: AppsRead?
    ) -> Int {
        if let read, let prefix, CanaryCommand.isValidPrefix(prefix) {
            var outside = SlotBook.OutsideUse()
            for slot in slots {
                let install = projected.installs.first { $0.id == slot.id }
                let id = bundleId(of: slot.app, recorded: install?.bundleId, prefix: prefix)
                let shown = id.map { read.shows($0) } ?? false
                let settled = usable(slot, takenAt: read.takenAt) ? SlotRule.settle(slot, present: shown, takenAt: read.takenAt) : slot
                guard SlotRule.used(settled), !shown else { continue }
                if settled.lentTo != nil { outside.lent += 1 } else { outside.pending += 1 }
            }
            return read.snapshot.usage(prefix: prefix, reserved: reserved, outside: outside, profiles: nil).free
        }
        let withSlot = Set(slots.map(\.app))
        let signed = Set(ledger.freeSigned.filter { $0.device == alias && !withSlot.contains($0.app) }.map(\.app))
        let used = signed.union(slots.filter(SlotRule.used).map(\.app))
        return max(0, MenuSnapshotBuilder.slotLimit - used.count - reserved)
    }
}
