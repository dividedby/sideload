# AGENTS.md — rules for agents working in this repo

`sideload` signs and installs apps on the owner's own Apple devices with the owner's paid Apple Developer
team, and (owner decision 2026-10-23) in a narrow way with the owner's free team as an interim route while the
paid install block stands. Read `README.md` (account status) and `docs/design.md` (section 18 for the free
team) before changing anything.

This file is the single source of truth for every agent. Claude Code reaches it through `CLAUDE.md` (`@AGENTS.md`)
and also loads the path-scoped detail in `.claude/rules/`; other agents should read the files linked below.

## Commands

- `pnpm test` (the secrets scanner's `node --test` suite), `pnpm check-secrets:all`, `pnpm format:check` (Prettier;
  CI also runs `shfmt` and `swift-format`, see `.github/workflows/format.yml`; files format on edit through the post-edit hook).
- `swift build` and `swift test` (no third-party packages, so no network; the tests use fakes, temp homes and fake HTTP).
- `scripts/check.sh` is the local gate: `swift build`, `swift test`, a release build of the CLI that proves the debug-only
  `SIDELOAD_TEST_FORCE_SLOT` hook is compiled out, `pnpm test`, `check-secrets --all`. Run it before opening a PR.
  Real-device runs are manual and owner-initiated.

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
  and never touches mobile-safari-lab. `canary`, `portal` and the
  ledger's certificate/profile lists stay paid-only. Signing code matches identities by certificate OU, never by
  name. Detail: `docs/design.md` section 18.
- **One lock for the free team.** `$SIDELOAD_HOME/.op.lock` is the shared operation lock for any signing with
  6ZU5Z6ZKK7. mobile-safari-lab takes it too (`dividedby/mobile-safari-lab-archive` issue 63, sideload #2), so a sideload run
  and a lab run never sign at the same time. Take it before touching that team's identity or profiles. A busy
  lock means a manual run reports `OPERATION_IN_PROGRESS` and auto-refresh logs a skip; never wait on it or
  delete the file. The lock is a BSD `flock` (`LOCK_EX|LOCK_NB`) and
  the only ordering mechanism with the lab: don't probe for its processes (no `pgrep`). Detail: `docs/design.md`
  sections 9 and 18.

## Apple TV

- sideload serves the Apple TV (`io.github.dividedby.free.stremio`, free team). atvloadly (Docker in the OrbStack VM
  `atv`) is retired: never set atvloadly up again or run it with the owner's Apple ID, and
  leave OrbStack itself alone (other projects use its Docker).
- The route is Xcode pairing on the Mac + `xcrun devicectl`, with the free team, or the paid team once the canary
  reports `working`. The owner pairs the Apple TV in Xcode; agents never pair or unpair devices.

## Secrets

- Never in the repo: `.p12`, private keys, provisioning profiles, Apple ID credentials,
  device UDIDs / CoreDevice IDs, IPAs. State lives in `$SIDELOAD_HOME` (default `~/.sideload`, 0700) or the
  macOS keychain.
- Never print secrets in output or logs. UDIDs are redacted to their last 4 characters. Identity common names
  are never printed (one contains an email address).
- `$SIDELOAD_HOME/asc/` (the App Store Connect API key `.p8` and `key.json`) and the app-data backups under
  `$SIDELOAD_HOME/backups/` are never read, opened, printed or copied by an agent.
- The pre-commit hook (`.githooks/pre-commit` → `scripts/check-secrets.mjs --staged`) must stay enabled.
  `pnpm install` sets `core.hooksPath`. Never bypass it with `--no-verify`.
- Detail: `.claude/rules/secrets.md`.

## Ask the owner first

These are the owner's to run or click. An agent prepares and explains them; it never runs them on a real device or
the real `$SIDELOAD_HOME`. Full list with the exceptions: `.claude/rules/owner-only.md`.

- `canary`, `provision`, `sign`, `install`, `refresh` (any mode, `--auto` included), `app remove`, `slot restore`,
  `slot lend|return` (run by the lab), `device remove|lendable|auto-refresh|slots`, `--register-device`, `fetch --approve`,
  `clean --yes`, `source add` (any form) and `source remove --yes`, `status --notify`, a live `portal` run, `scripts/install-local.sh`
  (except `--check`) and `launchctl`.
- Every action button in the menu bar app: agents never click them, never run the built app, never drive it.
- Pairing changes, any new download source, deleting anything from the keychain or the developer portal, anything
  system-wide or needing root, and changing `freeSlotsReserved` or `reservedAppIds`.
- Read-only and fine for an agent: `status`, `status --print-agent`, `refresh --print-agent`, `updates`, `source list`,
  `clean` without `--yes`, `scripts/install-local.sh --check`.

## Downloads

- IPAs and source only from upstream releases the owner approved (`approvedSources` in config). Record
  version + SHA-256 of everything downloaded; verify before signing.
- A new source is allowed only when the owner confirms its URL and exact hosts, by `source add --yes` or the menu bar app's
  confirm click. Agents never pass that flag, never click it and never add a source to `config.json`. Each version from any
  source still needs the owner's approval, with version and SHA-256 recorded (issue 47).

## Code

- Swift is the implementation (`docs/design.md`): Swift 6 language mode, macOS 27 / arm64, zero third-party
  packages, `SideloadCore` and the `sideload` CLI target import no AppKit/SwiftUI (`ImportBoundaryTests`). The `SideloadMenu`
  target is the only UI target and holds views, the view model and the app delegate's OS wiring (signals, terminate) only;
  the logic, timings included, lives in `Sources/SideloadCore/Menu/`. Tests use Swift Testing (`import Testing`), not XCTest.
- Node remains only for `scripts/check-secrets.mjs` and its test (plain ESM, zero dependencies).
- `portal` is GET-only: no code path may send a mutating HTTP method or a request body (a test scans `Sources/`).
  Network access goes through `Services.http`, whose default throws; tests never touch the network.
- Subprocesses via the Swift `Runner` (`Sources/SideloadCore/Exec/`) only: argument arrays, never a shell
  string, a timeout on every call. Network calls and polling are bounded.
- Every command prints exactly one JSON object: `{ ok, command, ..., errors: [{ code, message, fix }] }`,
  exit 0 iff `ok`. Progress goes to stderr.
- Target saved device IDs only (`sideload device save`), never "whatever is connected".

## Issues

- Tracker, labels and the Idea Inbox: `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`.
- Ideas: Idea Inbox is issue #1 (label `idea-inbox`); protocol in `docs/agents/idea-inbox.md`.
- Issue text follows the Secrets rules: no UDIDs, identity names, device names or credentials.

## Where things live

| Topic                                                                | File                                                                |
| -------------------------------------------------------------------- | ------------------------------------------------------------------- |
| "Ask the owner first" (full list, read-only exceptions, menu app)    | `.claude/rules/owner-only.md`                                       |
| "Secrets" (backups, `asc/`, ledger, redaction, hook)                 | `.claude/rules/secrets.md`                                          |
| Free team, shared lock, refresh, `refresh --auto`, takeover, history | `docs/design.md` sections 9, 18; `CHANGELOG.md` for dated history   |
| Issue tracker, labels, Idea Inbox                                    | `docs/agents/issue-tracker.md`, `triage-labels.md`, `idea-inbox.md` |
