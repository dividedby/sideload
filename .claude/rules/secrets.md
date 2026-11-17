---
paths:
  - "scripts/check-secrets.mjs"
  - "test/check-secrets.test.mjs"
  - ".githooks/**"
  - "Sources/SideloadCore/Portal/**"
  - "Sources/SideloadCore/Keychain/**"
  - "Sources/SideloadCore/Output/Redactor.swift"
  - "Sources/SideloadCore/Commands/AppDataBackup.swift"
  - "Sources/SideloadCore/Commands/CleanBackups.swift"
  - "Sources/SideloadCore/Commands/Slot*.swift"
---

# Secrets

Moved from AGENTS.md, which keeps the hard rules.

- Never in the repo: `.p12`, private keys, provisioning profiles, Apple ID credentials,
  device UDIDs / CoreDevice IDs, IPAs. State lives in `$SIDELOAD_HOME` (default `~/.sideload`, 0700) or the
  macOS keychain.
- Never print secrets in output or logs. UDIDs are redacted to their last 4 characters. Identity common names
  are never printed (one contains an email address).
- `ledger.json` holds no secrets.
- `$SIDELOAD_HOME/asc/` (the App Store Connect API key `.p8` and `key.json`) is never read, opened, printed or
  copied by an agent. Tests generate throwaway P-256 keys at runtime.
- App-data backups under `$SIDELOAD_HOME/backups/` (`slot lend` saves the lent app's data container) are secrets-class: they hold
  session tokens. Directories 0700, files 0600; never print, log, put in JSON, the ledger or the repo, and agents never open,
  read or copy them. Output carries counts and booleans only. The restore (`copy to`, in `slot return` and `slot restore`) was
  first checked live on a Wi-Fi iPhone (history: `CHANGELOG.md`, 0.2.0, app-data backup); `slot restore` itself has not been run on a device (as of the last docs pass; recheck before relying on it).
- The pre-commit hook (`.githooks/pre-commit` → `scripts/check-secrets.mjs --staged`) must stay enabled.
  `pnpm install` sets `core.hooksPath`. Never bypass it with `--no-verify`.
