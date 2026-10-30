# Contributing

sideload signs and installs apps on your own Apple devices with your own Apple Developer team, paid or free, using only
Apple's tools. It is maintained in spare time. Support isn't guaranteed, but issues and pull requests are welcome and
I'll try to get to them.

## Before you start

- Read `README.md` (what is built and how to set it up) and `AGENTS.md` (the repo's rules; they apply to people as much
  as to agents). `docs/design.md` is the full design; section 18 covers the free team.
- It is written for one setup today: the team IDs are constants in `Sources/SideloadCore/Config/Config.swift`
  (`Team.paid`, `Team.free`) and the bundle ID prefix is `bundleIdPrefix` in `config.json`. To use it with your own
  account, fork it and change those.
- Requirements: an Apple Silicon Mac on macOS 27, Xcode with your account added (Settings > Accounts), Swift 6, and
  pnpm (never npm or yarn).

## Issues

- Bugs and scoped requests: open an issue. Loose ideas go in the Idea Inbox (issue #1).
- Never put device UDIDs or CoreDevice IDs, device names, signing identity names, Apple ID details, certificates,
  profiles, `.p12` files or IPAs in an issue, a log you paste, or a screenshot. sideload's own output already masks
  device IDs to their last four characters.
- Security problems: don't post details publicly. Open an issue that says only that you have a security report, and
  I'll arrange a private channel.

## Making a change

1. Run `pnpm install` once. It sets `core.hooksPath` so the pre-commit secrets check (`scripts/check-secrets.mjs`)
   runs on every commit. Never bypass it with `--no-verify`.
2. Branch off `main`. Keep the change focused.
3. Follow the code rules in `AGENTS.md`:
   - Swift 6 language mode, zero third-party packages.
   - Tests use Swift Testing (`import Testing`), never XCTest. Tests never touch the network, a real device, your
     login keychain or the real `~/.sideload` (one opt-in keychain test uses a throwaway keychain).
   - `SideloadCore` imports no AppKit or SwiftUI.
   - Subprocesses go through the `Runner` only: argument arrays, never a shell string, a timeout on every call.
   - Every command prints exactly one JSON object `{ ok, command, ..., errors: [{ code, message, fix }] }` and exits 0
     iff `ok`.
   - `portal` stays GET-only.
4. Update `README.md`, `CHANGELOG.md` (under `## [Unreleased]`) and `docs/` in the same pull request.
5. Run `scripts/check.sh` and make sure it passes before you open the pull request. CI must be green; pull requests are
   merged with a merge commit.

By contributing, you agree that your contribution is licensed under the MIT License (`LICENSE`).

## Guidance for AI agents

If an AI coding agent works on this repo, for you or on its own, these rules bind it. Most tools read `AGENTS.md`
automatically; if yours reads only another file (for example `CLAUDE.md`), point it at `AGENTS.md`.

- **Read `AGENTS.md` first and follow it.** Where this file and `AGENTS.md` differ, `AGENTS.md` wins.
- **Apple tools only.** Never run or suggest third-party sideloading tools (iLoader, Sideloadly, AltServer, SideStore
  pairing, Impactor and similar) with anyone's Apple ID.
- **No credentials.** Never ask for, type or store an Apple ID password, and never read, print or copy keys,
  `.p12` files, profiles, the App Store Connect key under `$SIDELOAD_HOME/asc/`, or app-data backups under
  `$SIDELOAD_HOME/backups/`.
- **Ask before anything that changes a device, the developer portal, the keychain or the owner's state.** Everything
  `AGENTS.md` lists under "Ask the owner first" is the device owner's to run, including (not limited to) `canary`,
  `provision`, `sign`, `install`, `refresh` in any mode, `app remove`, `slot restore`, `export-cert`, a live `portal`
  run, `device remove`, `device lendable`, `device slots`, `device auto-refresh`, `--register-device`,
  `fetch --approve`, a new download source, `status --notify` against the real home, `clean --yes`, pairing and
  launchd agents. An agent prepares and explains them; the owner runs them. The read-only commands `AGENTS.md` allows (`status`, `updates`,
  `refresh --print-agent`, `status --print-agent`, and `clean` without `--yes`) are fine.
- **Tests stay hermetic:** fakes for the network, devices and keychain; temp homes; throwaway keys generated at runtime.
- **Say what you ran.** In the pull request, say that an agent wrote or helped with the change, and list the checks it
  ran (`scripts/check.sh`, anything run by hand). Don't claim a device run that didn't happen.
- pnpm only, no `--no-verify`, and no secrets in commits, issues or pull request text.
