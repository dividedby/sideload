# tvOS install and atvloadly coexistence

Researched 2026-10-19. Web research plus local `--help` output only. Nothing was run against a device.

**Status 2026-10-30:** historical. The free-team route took over the Apple TV on 2026-10-24 (`docs/design.md` section 18, spike S7), and atvloadly is retired: stopped and its Stremio copy removed on 2026-10-24, the `atv` VM deleted on 2026-10-30. The coexistence questions below are moot.

## Summary

- Install on a paired Apple TV with `xcrun devicectl device install app --device <id> <path.app>`. It takes a `.app` bundle, not an `.ipa` (local `--help`). Unzip the IPA's `Payload/*.app` first.
- Coexistence verdict: **probably safe, confidence medium-low.** No source I found says that pairing a second host revokes the first. No source says it is safe either. The point is unproven.
- atvloadly pairs through the same Apple TV pairing-mode screen (Remote App and Devices) that Xcode uses. Its docs name the Bonjour service `_remotepairing-manual-pairing._tcp`. Each host should hold its own pair record.
- The migration is staged and reversible. The first step that touches anything outside the Mac is pairing the Apple TV itself. Every step that changes atvloadly or the `atv` VM needs owner sign-off.
- The signing blocker (0xe8008018) is account-side. The tvOS route inherits it until Apple support resolves the case.

## Installing with devicectl

Command shapes, copied from local `--help`:

```
xcrun devicectl list devices --json-output -
xcrun devicectl device install app   --device <id> <path/to/App.app> --json-output <file> --timeout <s>
xcrun devicectl device uninstall app --device <id> <bundle-identifier> --json-output <file> --timeout <s>
xcrun devicectl manage pair          --device <id>      # state-changing, owner only
```

- `--device` accepts the CoreDevice UUID, ECID, serial number, UDID, name, or DNS name. Use the saved CoreDevice UUID to match the "saved device IDs only" rule.
- `--json-output <path>` writes JSON to a file. `-` writes it to stdout and moves human-readable output to stderr. Per local help, the JSON is "versioned and will remain stable", while stdout text is not stable. Parse the JSON only.
- On failure, devicectl exits non-zero. I did not run an install, so the exact JSON error shape is **Unverified**. My expectation is an `error` object with `code`, `domain` and `userInfo`, where the underlying message would carry the 0xe8008018 text. Capture it once on the canary run and pin the parser to that.
- Always pass `--timeout`. The spec requires bounded calls.
- `install app` has no tvOS-specific flags. The device platform is detected automatically.

Pairing the Mac with an Apple TV (Xcode or CoreDevice):

1. On the Apple TV, open Settings > Remotes and Devices > Remote App and Devices. Leave that screen open.
2. On the Mac, use Xcode > Window > Devices and Simulators, or `devicectl manage pair`. Enter the code shown on the TV.
3. The Mac stores the CoreDevice pairing in its own state. The exact on-disk location is **Unverified**. It is probably under `~/Library/Developer/CoreDevice/` or in the system keychain, but I did not inspect it.
4. The libimobiledevice man page confirms that pairing mode lives at Settings > Remotes and Devices > Remote App and Devices.

Known flakiness (Apple forums, older tvOS/Xcode): pairing loops back to the code screen. Reported fixes are toggling Wi-Fi, unplugging Ethernet from the Apple TV, rebooting the Mac or Apple TV, and removing the Mac from the Apple TV's list before retrying.

## Pairing coexistence with atvloadly

**Verdict: probably safe (medium-low confidence). Treat as "unknown, low-risk, recoverable".**

Evidence:

- atvloadly's README describes the same flow as Xcode: put the Apple TV in pairing mode under Remote App and Devices, then pair from its web UI. It relies on `_remotepairing-manual-pairing._tcp`. It names Impactor, idevice (Rust), usbmuxd2 and frida-core as components. It does not mention netmuxd, pymobiledevice3 or go-ios.
- The atvloadly pair record location is not stated in the README. It is presumably under the container's `/data` mount (**Unverified**).
- The atvloadly README FAQ says re-pairing is needed after Apple TV system upgrades. A tvOS update is therefore a bigger risk to atvloadly than Xcode pairing is. Do not update tvOS during this work.
- pymobiledevice3 release notes describe per-device RemotePairing records stored on the host, and a change that made old Wi-Fi-matching records stale. That suggests records are host-held key material. Revocation is not mentioned.
- I found no atvloadly issues about Xcode, re-pairing or lost pairings. A GitHub issue search for "xcode" returned nothing relevant. Absence of reports is weak evidence.
- Multiple-host limits on tvOS are **Unverified**. Nothing I found documents a cap or says that a new pairing revokes older ones. Apple forum users do remove a Mac from the Apple TV's list manually, which means the list can show several hosts.

Owner checks after pairing (all read-only):

1. On the Apple TV, open Remote App and Devices and confirm both hosts are listed. One entry for the Mac and one for atvloadly's pairing. Do not remove either.
2. In the atvloadly web UI, confirm the Apple TV still shows as connected and the existing Stremio app still launches. Do not click Refresh or Install.
3. Check that the next scheduled atvloadly refresh succeeds. Free-account apps expire after 7 days, so the next refresh is the real test.
4. If atvloadly loses the device, re-pair from its UI. That is the stated recovery path, and the Mac pairing is unaffected.

Do this before pairing: note the date of atvloadly's last successful refresh and the Stremio expiry date, and screenshot the Apple TV's Remote App and Devices list.

## Migration path

Every step marked **[sign-off]** requires owner sign-off.

1. Pre-flight: record atvloadly's last refresh and Stremio expiry (read-only). Check that the open Apple Developer Support case is resolved. Do not proceed to step 3 until it is.
2. **[sign-off]** Pair the Mac with the Apple TV (Xcode). Run the owner checks above.
3. Canary: build or obtain a trivial signed tvOS `.app` under a new, unique bundle ID (for example a dedicated `*.canary` ID). Install with `devicectl`, confirm it launches, then uninstall it. This proves the paid-team pipeline without touching Stremio.
4. **[sign-off]** Install Stremio via the paid team under a different bundle ID from atvloadly's copy. The same bundle ID would overwrite atvloadly's copy. It would also fail or clobber data if the signing team differs. Two copies side by side is the safe parallel setup.
5. Verify for N days (suggest 14, and at least one full atvloadly refresh cycle). Check that the paid copy launches, that the atvloadly copy keeps refreshing, and that the Mac pairing survives Apple TV sleep and reboots.
6. **[sign-off]** Owner decision to cut over. If the paid copy should use the original bundle ID, uninstall atvloadly's copy first (this loses its app data).
7. **[sign-off]** Stop atvloadly's refresh for the Apple TV (do not delete the VM or its pair record). Keep it in a stopped state for one more cycle as a rollback.
8. **[sign-off]** Only after that, decommission atvloadly or the `atv` VM.

Rollback at any step: remove the paid copy with `devicectl device uninstall app`. atvloadly is untouched until step 7.

## tvOS signing notes

- A tvOS development profile is a separate profile with platform tvOS ("tvOS App Development"). An iOS profile cannot be used for tvOS (Apple forum and tutorial reports).
- The Apple TV must be registered as a device on the team. Xcode registers it automatically on pairing when signed in. For a manual route, the identifier appears in Xcode's Devices and Simulators window.
- A wildcard App ID such as `com.example.*` is accepted for tvOS development profiles (tutorials cite Xcode's wildcard App ID in tvOS profiles). Whether one wildcard ID covers both iOS and tvOS profiles in the portal is **Unverified**. App IDs are platform-neutral in the portal, but profiles are per platform, so the ID can likely be shared and the profiles cannot.
- Apps that need entitlements (Top Shelf, push) require explicit App IDs. A wildcard breaks those.
- A mismatch between the wildcard prefix and the app's real ID produces "valid provisioning profile not found" (Apple forum thread 47817).

## Open questions

1. Does tvOS keep one pairing per host, and is there a maximum? Needs a test on the owner's hardware.
2. Exact JSON shape of a devicectl install failure, including 0xe8008018. Capture it on the canary run.
3. Where does CoreDevice store the Apple TV pair record on macOS 27?
4. Where does atvloadly store its pair record, and does it survive a container recreate?
5. Does a wildcard App ID cover iOS and tvOS in one portal entry?
6. Does Stremio's tvOS build need entitlements that a wildcard App ID cannot carry?

## Sources (accessed 2026-10-19)

- Local `xcrun devicectl --help`, `device install app --help`, `device uninstall app --help`, `manage pair --help`: command shapes, `--device` forms, `--json-output`, `--timeout`.
- https://github.com/bitxeno/atvloadly : atvloadly pairing flow, `_remotepairing-manual-pairing._tcp`, components, re-pairing after system upgrade.
- https://github.com/bitxeno/atvloadly/issues?q=xcode : no Xcode or re-pairing issues found.
- https://man.archlinux.org/man/idevicepair.1.en : Apple TV pairing mode path (Remotes and Devices > Remote App and Devices).
- https://newreleases.io/project/github/doronz88/pymobiledevice3/release/v9.33.0 : RemotePairing records are per-device and host-stored.
- https://developer.apple.com/forums/thread/695639 and https://developer.apple.com/forums/thread/669473 : Xcode and Apple TV pairing problems and fixes.
- https://developer.apple.com/forums/thread/47817 : wildcard App ID and profile mismatch error on Apple TV.
- https://github.com/Moonshine-IDE/SystemHealthAlerts-tvOS/wiki/Install-and-run-tvOS-project-on-AppleTV-using-Xcode : tvOS device UDID registration and tvOS profile type.
