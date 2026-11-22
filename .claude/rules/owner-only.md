---
paths:
  - "Sources/**"
  - "scripts/**"
---

# Ask the owner first

Moved from AGENTS.md, which keeps the short version. Anything on this list is the owner's to run or click; an agent
prepares and explains it.

- Deleting anything from the keychain or the developer portal.
- Installing anything system-wide, or anything that needs root/elevated privileges.
- Pairing changes and any new download source (`source add --yes`, `source remove --yes` and the menu bar app's "Add
  source…" and "Remove source…" confirm clicks are built and are the owner's; restoring a removed apollo or Stremio source is a
  `source add`, the owner's too. The one-time migration of the three former built-in sources is the single case where sideload
  writes source entries without the owner's confirm: it copies only what shipped in code, decision 2026-11-21). Agents never run `source add`, with or without `--yes` (its
  preview makes a network GET to an arbitrary address), and never run `source remove --yes`, against the real
  `$SIDELOAD_HOME`; they never click "Add source…" or "Remove source…" in the app. Tests run them against a temp home and fake HTTP.
- Running `canary`, `provision`, `sign`, `install` or `refresh` (any mode) on a real device, from the CLI or from the menu
  bar app's buttons (they change the portal and/or the device), and `app remove` (it uninstalls one managed install to free a slot; owner-only, allowlisted
  to `io.github.dividedby.free.*`, `--yes` is the owner's), and `slot restore` (the owner's retry of an app-data restore: it
  pushes a saved backup into the app on the device; owner-only, `--yes` is the owner's, and it takes `--device <alias>`, never
  `--udid`).
- The menu bar app's action buttons (Renew…, Add app…, Update…, Reinstall previous version…, Install, Remove, Lendable, Turn auto-renew on…/off…, Add device…, Add source…, Remove source…, Register and retry… and the confirm that follows them). They are owner
  clicks: the confirm click is the owner's `--yes` (Add device…'s is `device save --yes`, which turns auto-renew on for a new device; Turn auto-renew on…/off…'s is `device auto-refresh --on|--off --yes`, config only; Register and retry…'s also is `--register-device`), Add app… and Update… run fetch, approve, provision, sign and install on a real device
  (their second confirm is the owner's approval of that exact version and file; Update… goes over an installed app; Reinstall previous version… has one confirm and
  signs and installs an older, already approved build over the installed app, and `sign --version` is owner-run like `sign`), and agents never click them, never run the built app and never drive it
  (no computer-use clicks, no UI scripting), exactly as for the commands behind them.
- `scripts/install-local.sh` (it replaces the installed CLI the launchd agents run and the menu bar app, and restarts the app;
  `--kick` starts a `refresh --auto` run on the real devices). Its `--check` only reads the agents' state and the log, so an
  agent may run that.
- `clean --yes` (it deletes app-data backups past 14 days, downloaded IPAs no longer needed and stale build output under `builds/`: signed builds the ledger shows installed and past 14 days, orphans, the `carrier-dd` and `canary` caches; `--yes` is the owner's). `clean` without `--yes` is a preview that deletes
  nothing and prints counts only; agents may run it. It takes `.op.lock`, so a busy lock is `OPERATION_IN_PROGRESS`.
- `device remove --yes` (it retires a saved device: drops its config entry, ledger records, cached profiles and signed
  builds; it touches no device).
- `device lendable` (it chooses which app the lab may borrow the slot of). `slot lend` and `slot return` are run by
  mobile-safari-lab with no `--yes`; agents never run them against a real device, and they take `.op.lock`, accept
  `--udid` only for a saved device and never print it.
- `--register-device` (registers a device on the free team), `device auto-refresh`, and bootstrapping launchd
  agents (`launchctl`). `status --notify [--check-updates]` against the real `$SIDELOAD_HOME` (it posts a notification and
  writes `lastNotified` in `config.json`; with `--check-updates` it also does one metadata GET per approved source, no
  download, and writes `updates.json`; the owner's status agent runs it). `status` and `status --print-agent` are read-only
  and safe for an agent to run.
- Changing `freeSlotsReserved` or `reservedAppIds` (the free team's slot and App ID budgets).
- Running `portal` live (it uses the team's API key; owner-initiated).

## Read-only commands an agent may run

- `refresh --print-agent` is pure (no lock, subprocess or write), so an agent may run it, but only the owner runs the
  `launchctl` commands it prints (`docs/design.md` section 18). `refresh --auto` is the command the owner's launchd
  agent runs; agents never run it on a real device.
- `sideload updates` is read-only and safe for an agent to run: one metadata GET per approved source, no IPA download,
  no lock, no device, and it writes only `$SIDELOAD_HOME/updates.json`. It never approves, fetches, signs or installs
  anything; a newer version it reports is still `fetch`, the owner's `--approve`, `sign` and `install`.
- `sideload source list` is read-only and safe for an agent to run: no network, no lock, no device, no write. It lists
  every source (apollo, stremio-ios and stremio-tvos included, which the one-time migration of 2026-11-21 made ordinary
  `customSources` entries), with its exact hosts and whether `approvedSources` approves it. It never writes the migration; the
  first config write or `status --notify` does. `source add` without
  `--yes` is a preview that writes nothing, but it does one GET to the address it is given, so it is the owner's to run
  too (see "Ask the owner first").
