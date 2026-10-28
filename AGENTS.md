# AGENTS.md — rules for agents working in this repo

`sideload` signs and installs apps on the owner's own Apple devices with the owner's paid Apple Developer
team, and (owner decision 2026-10-23) in a narrow way with the owner's free team as an interim route while the
paid install block stands. Read `README.md` (account status) and `docs/design.md` (section 18 for the free
team) before changing anything.

## Account and tools

- Paid team: **7AGMPUPP64**. Every development install from it currently fails on device with
  `0xe8008018` (an open Apple Developer Support case). `sideload canary` reports whether that is fixed.
- **Apple tools only:** Xcode, `xcodebuild`, `codesign`, `security`, `xcrun devicectl`. Never run iLoader,
  Sideloadly, AltServer, SideStore pairing, Impactor or similar with the owner's Apple ID — they create
  certificates on the team and may have contributed to the block.
- **Never ask for, type, or store an Apple ID password.** Xcode holds the account.
- **Free team 6ZU5Z6ZKK7 (owner decision 2026-10-23), narrow use.** sideload may sign with that team's existing,
  pinned Apple Development identity (matched by OU) and let `xcodebuild -allowProvisioningUpdates` create App IDs
  and 7-day profiles only for `io.github.dividedby.free.*`. It never creates, revokes or exports a certificate of
  that team (a changed free identity set after a build is a hard stop). It never installs, uninstalls, re-signs
  or launches any bundle ID outside `io.github.dividedby.free.*` (WebDriverAgent and atvloadly's apps included),
  and never touches mobile-safari-lab, atvloadly or the `atv` VM. `canary`, `export-cert`, `portal` and the
  ledger's certificate/profile lists stay paid-only. Signing code matches identities by certificate OU, never by
  name. `provision`, `sign`, `install`, `refresh` (manual), `app remove`, `slot restore` and `slot lend|return` are built (owner-run, or run by the lab for `slot lend|return`); `refresh --auto` and `--print-agent` are designed, not built (`docs/design.md` section 18). `refresh` runs `provision`, `sign` and `install`, each taking `.op.lock` itself, and spends no new App ID on a renewal.
- **One lock for the free team.** `$SIDELOAD_HOME/.op.lock` is the shared operation lock for any signing with
  6ZU5Z6ZKK7. mobile-safari-lab takes it too (dividedby/mobile-safari-lab#63, sideload #2), so a sideload run
  and a lab run never sign at the same time. Take it before touching that team's identity or profiles. A busy
  lock means a manual run reports `OPERATION_IN_PROGRESS` and auto-refresh logs a skip; never wait on it or
  delete the file. The lock is a BSD `flock` (`LOCK_EX|LOCK_NB`) and
  the only ordering mechanism with the lab: don't probe for its processes (no `pgrep`). `fetch` downloads without it; it takes it to record a verified file and for `--approve`.

## Apple TV

- atvloadly (Docker in the OrbStack VM `atv`) serves the Apple TV today with the free Apple ID. Don't stop,
  change, or re-pair atvloadly or the `atv` VM, and don't route the paid account through it.
- The owner pairs the Apple TV in Xcode and stops atvloadly's Stremio refresh; agents never pair or unpair
  devices and never touch atvloadly/`atv`. The route is Xcode pairing on the Mac + `xcrun devicectl`, with the
  free team (side by side with atvloadly's copy under a distinct bundle ID) or the paid team once the canary
  reports `working`. Migration off atvloadly needs owner sign-off (`docs/research/tvos-install.md`, the takeover
  checklist in `docs/design.md` section 18).

## Secrets

- Never in the repo: `.p12`, private keys, provisioning profiles, the `.p12` password, Apple ID credentials,
  device UDIDs / CoreDevice IDs, IPAs. State lives in `$SIDELOAD_HOME` (default `~/.sideload`, 0700) or the
  macOS keychain.
- Never print secrets in output or logs. UDIDs are redacted to their last 4 characters. Identity common names
  are never printed (one contains an email address).
- The `.p12` password lives only in the keychain (service `io.github.dividedby.sideload`, account `p12`); it
  reaches the owner only through `export-cert --copy-password` (concealed clipboard item, cleared after 90 s),
  never stdout, stderr, logs, the ledger, the kit or the repo. `ledger.json` holds no secrets.
- `$SIDELOAD_HOME/asc/` (the App Store Connect API key `.p8` and `key.json`) is never read, opened, printed or
  copied by an agent. Tests generate throwaway P-256 keys at runtime.
- App-data backups under `$SIDELOAD_HOME/backups/` (`slot lend` saves the lent app's data container) are secrets-class: they hold
  session tokens. Directories 0700, files 0600; never print, log, put in JSON, the ledger or the repo, and agents never open,
  read or copy them. Output carries counts and booleans only. `copy to` (the restore, in `slot return` and in `slot restore`) was
  first checked live on 2026-10-25 (mobile-safari-lab#63, Stage 2: an iPhone on Wi-Fi, stremio-ios, a backup of 11 of 13 files; after the return the app was still signed in with its library and add-ons); `slot restore` itself has not been run on a device.
- The pre-commit hook (`.githooks/pre-commit` → `scripts/check-secrets.mjs --staged`) must stay enabled.
  `pnpm install` sets `core.hooksPath`. Never bypass it with `--no-verify`.

## Ask the owner first

- Deleting anything from the keychain or the developer portal.
- Installing anything system-wide, or anything that needs root/elevated privileges.
- Pairing changes, atvloadly changes, and any new download source.
- Running `canary`, `provision`, `sign`, `install` or `refresh` (any mode) on a real device, from the CLI or from the menu
  bar app's buttons (they change the portal and/or the device), and `app remove` (it uninstalls one managed install to free a slot; owner-only, allowlisted
  to `io.github.dividedby.free.*`, `--yes` is the owner's), and `slot restore` (the owner's retry of an app-data restore: it
  pushes a saved backup into the app on the device; owner-only, `--yes` is the owner's, and it takes `--device <alias>`, never
  `--udid`).
- The menu bar app's action buttons (Renew…, Add app…, Install, Remove, Lendable and the confirm that follows them). They are owner
  clicks: the confirm click is the owner's `--yes`, Add app… runs fetch, approve, provision, sign and install on a real device
  (its second confirm is the owner's approval of that exact version and file), and agents never click them, never run the built app and never drive it
  (no computer-use clicks, no UI scripting), exactly as for the commands behind them.
- `device lendable` (it chooses which app the lab may borrow the slot of). `slot lend` and `slot return` are run by
  mobile-safari-lab with no `--yes`; agents never run them against a real device, and they take `.op.lock`, accept
  `--udid` only for a saved device and never print it.
- `--register-device` (registers a device on the free team), `device auto-refresh`, and bootstrapping launchd
  agents (`launchctl`).
- Changing `freeSlotsReserved` or `reservedAppIds` (the free team's slot and App ID budgets).
- Running `portal` live (it uses the team's API key; owner-initiated).
- Running `export-cert` against the real keychain (it exports the private key behind a keychain dialog, stores the
  `.p12` password item and writes the kit). `--yes` and `--copy-password` are owner-only flags: agents never pass
  them (`--copy-password` puts the password on the clipboard and keeps the command running for 90 s).

## Downloads

- IPAs and source only from upstream releases the owner approved (`approvedSources` in config). Record
  version + SHA-256 of everything downloaded; verify before signing.

## Code

- Swift is the implementation (`docs/design.md`): Swift 6 language mode, macOS 27 / arm64, zero third-party
  packages, `SideloadCore` imports no AppKit/SwiftUI (the `sideload` CLI target imports AppKit only for
  the pasteboard, in `Sources/sideload/Pasteboard.swift`; the `SideloadMenu` target is the only other UI target and holds views, the view model and the app delegate's OS wiring (signals, terminate) only; the logic, timings included, lives in `Sources/SideloadCore/Menu/`). Tests use Swift Testing (`import Testing`), not XCTest.
- Node remains only for `scripts/check-secrets.mjs` and its test (plain ESM, zero dependencies).
  **pnpm only** (never npm or yarn).
- `portal` is GET-only: no code path may send a mutating HTTP method or a request body (a test scans `Sources/`).
  Network access goes through `Services.http`, whose default throws; tests never touch the network.
- Subprocesses via the Swift `Runner` (`Sources/SideloadCore/Exec/`) only: argument arrays, never a shell
  string, a timeout on every call. Network calls and polling are bounded.
- Every command prints exactly one JSON object: `{ ok, command, ..., errors: [{ code, message, fix }] }`,
  exit 0 iff `ok`. Progress goes to stderr.
- Target saved device IDs only (`sideload device save`), never "whatever is connected".
- Tests: `scripts/check.sh` is the local gate (`swift build`, `swift test`, a release build of the CLI that proves the debug-only
  `SIDELOAD_TEST_FORCE_SLOT` hook is compiled out, `pnpm test` for the secrets suite, `check-secrets --all`); run it before opening a PR. Real-device runs are manual and owner-initiated.

## Git

- Identity: `dividedby <64715420+dividedby@users.noreply.github.com>` (set in the repo's local config).
- Feature branches off `main` → PR → merge commit only. CI must be green. Update README/CHANGELOG/docs in
  the same PR.

## Issues

- **Tracker:** GitHub issues in `dividedby/sideload` via `gh`. See `docs/agents/issue-tracker.md`.
- **Labels:** state `needs-triage`, `ready-for-agent`, `ready-for-human`, `blocked`, `wontfix`; category `bug`,
  `enhancement`, `chore`, `epic`; size `size:S/M/L/XL`. See `docs/agents/triage-labels.md`.
- **"file an idea"** or an unqualified **"file an issue"**: add an enriched row (the idea plus the context and
  links available now) to the top of `## Ideas` in the [Idea Inbox](https://github.com/dividedby/sideload/issues/1)
  (label `idea-inbox`, one per repo). Don't scope it yet. Capture and drain protocol:
  `docs/agents/idea-inbox.md`.
- **"file a *tracked* issue"** or a plainly scoped bug: skip the Inbox and file a `needs-triage` issue directly.
- Issue text follows the Secrets rules: no UDIDs, identity names, device names or credentials.
