# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

### Added

- Menu bar "Add app…": installs an app from `approvedSources` (Apollo, Stremio) that the device does not have yet. The
  per-device menu beside Renew… lists the approved sources for that platform with no row on the device (the filler and any
  unapproved source are hidden; an Apple TV card gets it like any device). The first confirm ("Fetch Apollo for iphone")
  runs `fetch` alone: it downloads and checks the latest release and changes neither the device nor the portal. The second
  confirm ("Approve and install Apollo 3.9.0 on iphone") shows the version, build, size, minimum OS and the full SHA-256,
  the extensions that will be removed, whether it costs a new App ID, and the slots; its click approves that exact
  version and file and runs `fetch --approve --version`, `provision`, `sign` and `install` (the owner's `--yes`). A
  fetched version opens the second confirm at once, with no result card and no re-read of the device. The run re-reads
  `manifest.json` first and refuses a file whose SHA-256 is not the one shown, skips `provision` when a stored profile has
  6 days or more left and `sign` when the signed build already is this version and profile, checks Cancel between steps, and
  checks that the signed build is the confirmed version before `install`; a run that stops halfway keeps what is done and
  the same Add app resumes. A disabled item says why: no free slot, the App ID budget, a device that is not connected, an
  app already on the device, or an OS older than the app's minimum. New: `MenuAction.addFetch` and `.addApprove`,
  `MenuFetched`, `MenuAddOption`, `MenuAddSource`, `MenuActionOutcome.proceed`, `MenuActionSteps.fetch/provision/sign`,
  `MenuDeviceCard.addable/osVersion`, `MenuSnapshot.addSources`.
  Retry after a failure past `sign` is Install (the row is then "Signed · not installed"); `provision` is retried once with
  `renew` on `PROFILE_NOT_RENEWED`, like `refresh`; the device note on a cancel appears only when `install` was called;
  a reused App ID is not blocked by an unknown budget; a Cancel that arrives after the fetch succeeded says "not approved".
- `fetch`'s "already stored" shortcut removes a `tmp/staged-<digest>.ipa` left for that digest.
- `SignOptions.version` (Core only, no CLI flag): `sign` signs exactly that fetched, approved version instead of the newest
  approved one (`NOT_APPROVED` when it is not both); nil keeps the old behaviour. The menu's Add app sets it.
- Menu bar actions: Renew… (All apps or one app, Retry on a failed renewal), Install and Install update, Remove and
  "Lendable: <App>" now run from the panel. Each opens an inline confirm that names the device alias and the app and
  states the effect (slots, App IDs, the keychain prompt); the confirm button is the owner's `--yes`. A running action
  shows Cancel (not for the lendable setting) and turns the other controls off; the result is done, failed (code,
  message and fix per app, with Retry), busy (the lock was held) or cancelled, and the device is then read again at
  once. A disabled control says why. Renew and Install need a visible device with a successful live read, except a lent
  app's Renew; Remove needs an installed row; the lendable setting is off while the device has a lent or pending row.
  Quitting with an action running cancels it (also during the command's post-result work), then kills its children;
  the result card shows an install's `warnings[]` as notes, and the lendable setting re-reads the ledger just before it
  runs and is not run while the device has a lent or pending slot. New: `MenuActions`, `MenuActionOutcome`,
  `MenuActionRunner`, `MenuActionState`, `MenuAppsCache.invalidate`, `AppsRead.shows`, `AppPresence.isLive`; the snapshot
  carries the facts the rules need. "All apps" lists the available apps `refresh` would select, names each one it
  leaves out and why, and is off only when none is available; it runs one `refresh --app` per listed app (stopping on a fatal
  error or a busy lock), so it cannot touch an app the confirm did not list, and the confirm click runs only the confirm that was shown (a changed
  one is shown again). The menu icon is `renewing` while a Renew from the menu runs.
- `RefreshPolicy.Result.cancelled`: when the menu's Cancel stops a `refresh` run (the task is cancelled and a step
  fails with a code the cancellation can explain), the app's result is `INTERRUPTED`, the attempt is given back and no failure, backoff or suspension is recorded
  (`lastResult: skipped`, `lastCode: INTERRUPTED`). The CLI is unchanged: signals still stop its process.
- Menu bar: the Apps card checks each visible device live. After `devicectl list devices`, the app runs one read-only
  `device info apps` per visible saved device (15 s timeout, one device after the other; no lock, no profile read, nothing
  written), at launch, on Check status now, and on a panel open only when the last attempt is 5 minutes old (a failed
  attempt counts, so a locked device is not retried at every open). A row is installed, "Signed · not installed" (recorded
  but gone from the device: no bar, out of the ring and the slot count), "Lent to lab", "Change in progress", or the
  ledger's countdown when the device could not be read; a card whose device could not be read says why once ("Couldn't
  check apps (device locked) · showing last known"). A signed app (`freeSigned`) with no other record shows once the device lists
  it (installed by hand) and, once a read at least as new as its slot record confirms it absent, as "Signed · not installed"
  (for instance after `app remove`), with an Install offer; with no usable read it has no row. New: `MenuLoader.readApps`, `visibleAliases`, `DeviceAppsProbe`, `MenuAppsCache`, `AppPresence`.
- Menu bar: a failed last renewal (`installs[].refresh.lastResult == "failed"`) shows "Renewal failed · CODE" in red under
  the row and sets the icon's renew-failed badge.

### Changed

- `fetch` downloads without `.op.lock` and takes it only to record the verified file (and for `--approve`, which holds it
  throughout), so a long download no longer blocks the lab or another command. Each run keeps a `live.lock` flock in its
  `tmp/fetch-XXXXXX/` folder; the sweep (now lock-free, in every fetch) removes a folder only when it is older than 60 s by
  real file time and its lock is free or missing, and removes a `staged-*` file after 24 hours. At commit the manifest is
  reloaded, so two fetches no longer lose each other's entry, and a version another fetch recorded first is returned as
  `downloaded:false` with its approval. A busy lock at commit is still `OPERATION_IN_PROGRESS` (never waited on), but the
  verified file is kept as `tmp/staged-<sha256>.ipa` (0600) for 24 hours and the re-run claims it instead of downloading
  again (it is hashed again first). CLI flags and the envelope are unchanged. New: `FileLock.tryAcquireExisting`,
  `FileLock.isLinked`.
- Menu bar: the Apps card, the ring and the status colour now come from `installs[]` and `slots[]`, not `freeSigned`; the
  expiry is the install's `profileExpires`, so a newer signed build that is not installed no longer moves it. An app with
  only a `freeSigned` record and no usable live read has no row. Free slots with a live read follow what `install` counts (the
  device's managed apps, the reserve, lent and pending records); without one, a signed app counts only while no slot
  record exists for it, so an app removed with `app remove` stops holding a slot. The Renew… menu is wired to `refresh` (see Added).
- `MenuLoader.readApps` takes the loaded config's `bundleIdPrefix` instead of reading the config again.
- `ExpiryItems.item(_:now:)` is shared by `status` and the menu; `FreeDeviceCalls.snapshot` and `trySnapshot` take a
  `timeoutSec` (default 60).

## [0.2.0] - 2026-10-28

The free team (6ZU5Z6ZKK7) as an interim route: `provision`, `sign`, `install`, `refresh` (manual) and `app remove`;
slots lent to mobile-safari-lab with app-data backup and restore; the paid team's ledger, portal audit and `export-cert`;
`inspect` and `fetch`; `status` and the `SideloadMenu` menu bar app. The entries that touch the lab-facing JSON add
fields; the free-slot counts and some app-data backup and restore results changed as Fixed describes, and the one change
in meaning is that `status`'s `state` now also follows free installs, so `ok` no longer implies a working canary (read
`canary.last` for that).

Not yet run on a real device or the real Mac through these commands (owner-run, see README; the spikes are in
`docs/design.md` section 18): `export-cert`, `provision` (spike S2), `sign` and `install` (spike S4), `refresh` (spike S5)
and `slot restore`. The restore that `slot return` does was checked live on 2026-10-25 (below).

### Added

#### Paid team: ledger, portal, export-cert and the canary

- `CertInfo.notBefore`, `CertCheck.selectedPaid`, profile expiry/creation/certificate fingerprints in the
  guard, and the device OS version/build in the device listing.
- `canary.jsonl` lines gain `macosVersion`, `iosVersion`, `certFp` (8 hex) and `certNotAfter`
  (`YYYY-MM-DD`); older lines stay valid.
- `canary history`: read-only summary of `logs/canary.jsonl` (`runs`, `skipped`, `statusCounts`,
  `lastWorking`, `firstBlockedAfterWorking`, `changes` over Xcode, macOS, iOS, certificate fingerprint and
  expiry, `recent`).
- `canary --evidence`: for a `blocked` or `error` result (opt-in, never for `working`) writes
  `$SIDELOAD_HOME/evidence/canary-<ts>/evidence.json` (schema 2) and `evidence.txt` (0700 folder, 0600 files)
  with the run, macOS/Xcode/iOS versions, the keychain certificate (OU, validity, first 8 hex of its SHA-1), the
  embedded profile (team, dates, device count, whether the device and certificate are in it), the codesign
  team and the install error, for manual attachment to an open Apple Developer Support case. The bundle is an allowlist
  built from structure, never a cleaned-up copy: the devicectl error chain is reduced to a closed set of
  fields per node (domain, code, 32-bit `codeHex`, the three `NSLocalized*` messages, `LegacyErrorString`,
  `LibMISErrorNumber` (only when exact, up to 2^53), and the "Failed to verify code signature of ... : 0x... (...)" template taken apart
  into `codeSignature`; the path is never kept), at most 8 deep and 16 nodes. An Apple message is admitted
  whole only if every character and word is on a fixed list and none is a name or hostname of the device,
  the login, the full name, the signing identity's person, or this Mac; otherwise it is left out and counted
  under `install.omitted`, never edited. stderr lines get the same filter (at most 20 kept). A separate
  verifier with its own matching checks the closed schema, the free-text fields and both rendered files, and
  writes nothing (warning `EVIDENCE_REDACTION_FAILED`) if anything is off. A write problem is the warning
  `EVIDENCE_WRITE_FAILED`; neither changes the canary `status` or exit code. The envelope gains an
  `evidence` key only when `--evidence` is passed (omitted otherwise, so existing envelopes are unchanged).
  The bundle is written to a temporary folder and renamed into place, so an interrupted run leaves no half bundle.
  `logs/canary-install-*.json` stays a local log of the raw (denylist-masked) devicectl document; it is not
  part of the bundle and is never attached.
- Optional `appleSupportCase` key in `config.json` (a string or an integer; 6 to 20 digits): the canary evidence bundle's
  `appleCase` field and `evidence.txt` carry it as a string; when unset, or not 6 to 20 digits, `appleCase` is null. A rewrite
  of `config.json` keeps the key as it was written (an integer stays an integer, a string a string). The case number is no longer
  in the source, the tests or the docs.
- `ledger` and `ledger refresh`: `$SIDELOAD_HOME/ledger.json` (schema 1, 0600, atomic writes under `.ledger.lock`,
  unknown keys preserved) records the paid team's Apple Development certificates (first 8 hex of the SHA-1,
  validity, `valid`/`present`) and provisioning profiles (UUID, application ID, wildcard, expiry, device count and
  last-4 tails, embedded certificate fingerprints) read from Xcode's profile folders, plus an `exports` list that
  `export-cert` appends to. `ledger` is read-only and prints expiry `items` (`ok` above 60 days, `warn` at 60
  or fewer, `critical` at 14 or fewer, `expired`); `ledger refresh` reads only public certificates and profiles
  (no private key, no keychain prompt, no `--yes`). The free team's certificates and profiles are never
  recorded. Errors: `LEDGER_INVALID` (never echoes the file), `LEDGER_WRITE_FAILED`, `KEYCHAIN_READ_FAILED`,
  `PROFILES_UNREADABLE`, `BUSY`.
- `ProvisioningProfile`, `ProfileSource` and `XcodeManagedProfileSource` (reads
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and the legacy `~/Library/MobileDevice/...`, decoding
  with `security cms -D -i` through the runner); `Services.profiles` (inert by default).
- `portal [certificates|bundle-ids|devices|profiles] [--show-identifiers]`: read-only audit of the paid team's
  developer portal through the App Store Connect API. Reads the owner's key from `$SIDELOAD_HOME/asc/`
  (`key.json` + `AuthKey_<KEYID>.p8`; permissions, owner and symlinks checked: `PORTAL_NOT_CONFIGURED`,
  `ASC_KEY_INVALID`, `ASC_KEY_PERMISSIONS`), mints a 10-minute ES256 token in process and lists the four
  resources with `GET` requests only (bounded: https to `api.appstoreconnect.apple.com`, four fixed paths,
  redirects refused, 20 pages of 200, 4 MiB per body, 120 s, two retries on 429/5xx/timeout). Output is an
  allowlist: names, serial numbers, common names and profile content are never requested or printed, UDIDs are
  last-4, certificates are the first 8 hex of their SHA-1, App ID identifiers print only under
  `bundleIdPrefix` unless `--show-identifiers`. Development certificates report `inKeychain`, and the summary
  counts `certificatesNotInKeychain`. The warning `TEAM_UNVERIFIED` says when no certificate or App ID was
  available to confirm the team (for example `portal devices` alone). A listing whose data is not team 7AGMPUPP64's is withheld
  (`TEAM_MISMATCH`, `FREE_TEAM_SELECTED`). A failing list (`ASC_FORBIDDEN`, `ASC_UNAUTHORIZED`,
  `ASC_RATE_LIMITED`, `ASC_HTTP_ERROR`, `ASC_NETWORK`, `ASC_RESPONSE_INVALID`, `PORTAL_TRUNCATED`) does not hide
  the others (the Apple error `code` stays in the error's data, never in the printed section). A cancelled run stops
  at its retry wait and is `CANCELLED`. No mutating HTTP code exists; a test scans `Sources/` for it.
- `Services.http` (`HTTPTransport`; the default throws, the live set uses an ephemeral `URLSession`) and
  `Services.sleep` (throws on cancellation); `Paths.asc`.
- The output redactor masks a JWT (`<jwt>`) and a PEM private-key block (`<private key>`) in stdout and
  `logs/commands.log`.
- Keychain layer behind `export-cert`: `IdentityExporter`
  (`SecItemExport` PKCS#12 with the passphrase in process, re-checks the paid team and never exports another
  team's key), `SecretStore` (the `io.github.dividedby.sideload` / `p12` password item: read and add only, never
  update or delete), `P12Verifier` (`SecPKCS12Import`, in memory only), `PromptGuard` (stops waiting for a keychain
  dialog after 120 s), `PasswordGenerator` (20 Crockford base32 characters in groups of four), `Pkcs12Inspector`
  (records the encryption scheme from the file's OIDs), `CertReference` (a validated certificate SHA-1) and the typed `KeychainFailure` (each case is a `{code, message, fix}`; the password item has its own `PASSWORD_STORE_FAILED` / `PASSWORD_UNREADABLE`). `Services` gains
  `identityExporter`, `secrets` and `p12Verifier`; the defaults are inert and throw `KEYCHAIN_UNAVAILABLE`. Spike
  results (macOS 27: the export works in process, writes legacy 3DES/RC2-40 encryption, the memory-only import
  leaves nothing in a keychain) are in `docs/design.md` sections 6 and 16. An opt-in test
  (`SIDELOAD_REAL_KEYCHAIN=1`) runs against a throwaway keychain only.
- `CertCheck.paidCandidates`, `Paths.gitWorkTree(containing:)` (also ignores a regular file as a candidate for `.git`).
- `export-cert --device <alias> [--profile <uuid>] [--out <dir>] [--copy-password] --yes` (owner-run; `--yes` and
  `--copy-password` are owner-only flags): exports the paid team's development identity as a password-protected
  `.p12` through the keychain layer (private key via `SecItemExport`, the password only in the keychain item
  `io.github.dividedby.sideload` / `p12`, never in argv, output, logs, ledger or kit), chooses the certificate and
  profile with a pure planner (valid paid-team certificate; unexpired iOS development profile for the team that lists
  the device and embeds the certificate; wildcard first, then later certificate expiry, then later profile expiry),
  verifies the file opens with the stored password and holds the expected identity, records the encryption scheme,
  appends the export to `ledger.json` (also merging the certificates and profiles it just read), and writes a Feather
  kit (`sideload-dev.p12`, the original signed `sideload-dev.mobileprovision`, `README.txt` with import steps,
  password sources, legacy-encryption note and expiry dates) to `exports/feather-<ts>/` or `--out`, built under a
  hidden name and renamed into place (`RENAME_EXCL`); the master `.p12` is also kept in `secrets/p12/`. A failure
  after the key leaves the keychain removes the `.p12` and the staged kit again. Warnings: `P12_LEGACY_ENCRYPTION`,
  `PROFILE_NOT_WILDCARD`. Errors: `USAGE`, `CONFIRM_REQUIRED`, `OPERATION_IN_PROGRESS`, `DEVICE_NOT_SAVED`,
  `CERT_NOT_FOUND`, `PROFILE_NOT_FOUND`, `DEVICE_NOT_IN_PROFILE`, `PROFILE_CERT_MISMATCH`, `IDENTITY_NOT_PAID_TEAM`,
  `KEYCHAIN_DENIED`, `KEYCHAIN_PROMPT_TIMEOUT`, `KEYCHAIN_READ_FAILED`, `PASSWORD_STORE_FAILED`, `PASSWORD_UNREADABLE`,
  `P12_VERIFY_FAILED`, `OUT_NOT_EMPTY`, `OUT_IN_GIT_WORKTREE`, `EXPORT_EXISTS`, `LEDGER_INVALID`,
  `LEDGER_WRITE_FAILED`, `BUSY`. The keychain dialogs (password item and private key) run under `PromptGuard`.
- `--copy-password`: puts the password on the general pasteboard marked `org.nspasteboard.ConcealedType` and
  `org.nspasteboard.TransientType`, so clipboard managers skip it and Universal Clipboard can paste it on the iPhone.
  The command stays running for 90 s (stderr says to paste now), then clears the pasteboard only if its change
  count is still the one the copy produced. Ctrl-C, SIGTERM and SIGHUP clear it at once, and the operation lock is
  released before the wait. `NSPasteboard` lives only in `Sources/sideload/Pasteboard.swift` (the CLI target)
  behind `SecretPasteboard` / `PasteboardBackend` in `SideloadCore`; `Services.pasteboard` is inert by default
  (`PASTEBOARD_UNAVAILABLE`), and there is no `pbcopy`. A failed copy is the warning `PASTEBOARD_FAILED` (the kit
  stands). There is no `--show-password`: the password never reaches stdout or stderr.
  Ctrl-C, SIGTERM or SIGHUP during the hold ends it early instead of printing `INTERRUPTED`: stderr says the kit
  path is "recorded in ledger" before the hold, then the clipboard is cleared (if still ours) and the normal result is
  printed (`clipboardCleared`, `clipboardHoldInterrupted: true`, exit 0); nothing says to re-run. With
  `--copy-password` both fields are always present: `clipboardHoldInterrupted` is true when any signal was absorbed
  (also during a failed copy); `clipboardCleared` is true when sideload cleared the password or never put it on the
  pasteboard (a signal before the copy), false when it cleared nothing (the owner copied something else, or the copy
  failed; a clear is attempted either way and its result reported).
  From the master `.p12` write until the kit is in place every signal is absorbed and the export itself cleans up:
  a signal before the ledger write removes the `.p12`, its temporary files and the staging folder (also beside
  `--out`) and reports `INTERRUPTED`; from the ledger write on the move finishes or rolls back and the clipboard step
  is skipped. The signal handler never touches files; a signal before the write starts marks the export dead and it
  writes nothing. Signals while the password is being copied are absorbed too and the export clears the pasteboard
  afterwards; the pasteboard's check-and-clear runs under one lock, so a second clear (the signal handler's) waits
  for the first to finish (at most 500 ms) and reports it as already cleared. If main's clear takes longer than that,
  the process exits with it still running and `clipboardCleared` is null. From the second signal while writing,
  committing or copying, stderr says "finishing cleanup; kill -9 to force". Once the kit exists, a second signal's
  `INTERRUPTED` object reports `kit`, `ledgerRecorded` and `clipboardCleared` instead of telling the owner to run
  again. Any error from the pasteboard after the kit exists is the warning `PASTEBOARD_FAILED`, not a failure; a clear
  is still attempted and `clipboardCleared` reports its result.
- `export-cert`: if the kit cannot be moved into place and the ledger rollback also fails, the error is
  `LEDGER_ROLLBACK_FAILED` (names the dangling export id, with a fix) instead of being swallowed.

#### IPAs: inspect and fetch

- `inspect <path.ipa>` (read-only; no `--yes`, no lock): reports `ipa{path,sizeBytes,sha256}`, `app{bundleId,name,
  version,build,minOS,platform,deviceFamily,executable,architectures,signed,entitlements,appGroups}`,
  `extensions[...]` for each `PlugIns/*.appex`, the union of app groups, `hasEmbeddedProvision`,
  `otherCode{frameworks,dylibs,watchApps}` (counts) and `warnings`. Architectures come from `lipo`, platform and
  minimum OS from `vtool`, entitlements from `codesign -d --entitlements - --xml`, all through the Runner (absolute
  paths, argument arrays, a timeout and an output cap on each). The IPA is untrusted: the central directory is
  checked before `ditto` runs, to reject known-bad listings (`ditto` extracts by the local headers, so this is not the
  guarantee; the `lstat` walk of the extracted tree is), and an unsafe entry (empty, NUL, backslash or control-character name, absolute
  path, `..` component, symlink, device, FIFO or socket) is a hard failure `IPA_UNSAFE_ENTRY`, as are more than 20,000
  entries or over 4 GiB declared (`IPA_TOO_MANY_ENTRIES`, `IPA_TOO_LARGE`); `ditto` unpacks into a 0700 `mkdtemp`
  folder under `$SIDELOAD_HOME/tmp` while a second task watches its size and cancels it past the cap (headers can
  lie); the result is walked with `lstat` and a symlink, special file, hard link or other volume is
  `IPA_UNSAFE_TREE`. `Info.plist` is bounded to 4 MiB, errors never quote file contents, `CFBundleExecutable` with a
  `/` is `IPA_EXECUTABLE_INVALID`, unsigned binaries report `signed: false` and `entitlements: null`, and strings from
  the archive are cut to 256 characters. The scratch folder is removed on every path, and the CLI's signal handler
  removes it too (`ScratchRegistry`) before the `INTERRUPTED` object. The portal comparison is deferred. Other
  errors: `IPA_NOT_FOUND`, `IPA_NOT_ZIP`, `IPA_UNSUPPORTED_ZIP`, `IPA_NOT_MACHO`, `IPA_NO_APP`, `IPA_MULTIPLE_APPS`,
  `IPA_EXTRACT_FAILED`, `IPA_EXTRACT_TIMEOUT`, `IPA_CHANGED`, `INFO_PLIST_MISSING`, `INFO_PLIST_TOO_LARGE`,
  `INFO_PLIST_INVALID`, `TOOL_FAILED`, `CANCELLED`; warnings: `CODESIGN_FAILED`, `BUILD_VERSION_UNREADABLE`,
  `ENTITLEMENTS_UNREADABLE`, `ENTITLEMENTS_TRUNCATED`, `EXTENSIONS_TRUNCATED`, `EXTENSION_NOT_A_BUNDLE`,
  `SCRATCH_NOT_REMOVED`. Design: section 8 and the section 16 risk entry.
- `fetch --app <apollo|stremio-ios|stremio-tvos> [--approve --version <v>]` (docs/design.md section 8 and section 18, build step 4).
  Downloads one approved IPA over `Services.http` and records it: the manifest (`manifest.json`, schema 1, 0600) holds
  `{app, version, file, urlHost, sha256, upstreamDigest, size, declaredSize, build, minOS, inspectMinOS, fetchedAt, approved, approvedAt}` (`minOS` is Stremio's `minOSVersion`, read from a string, integer or float and written without a float artefact; `inspectMinOS` is the Mach-O floor `inspect` read, for every app, for `sign` to check against the device; the new fields are optional when reading) and the file sits at
  `downloads/<app>/<version>/<file>`. Apollo Reborn: GitHub `releases/latest`, tag `v<x>_<ver>`, the asset named
  exactly `Apollo-Reborn-<ver>-GLASS-NOEXTENSIONS.ipa` (the `-NOEXTENSIONS`, `-GLASSICONS-NOEXTENSIONS`, `-GLASS`,
  dSYMs and `.deb` look-alikes never match), digest from the API asset's `digest` field. Stremio: the gorlev
  `stremio-ios.json` and `stremio-tvos.json` indexes (bundle ID `com.stremio.pal` for both, separate app keys),
  `versions[0]`, tvOS URL pinned to `https://dl.strem.io/apple/<ver>b<build>/tvos/stremio_tvOS.ipa`. A missing or
  malformed upstream digest is `UPSTREAM_DIGEST_MISSING` and nothing is downloaded. Sources must be listed in
  `approvedSources` (`{"app": "<key>"}`, optional narrowing `hosts`); the catalog pins the metadata and download
  hosts (api.github.com, github.com, objects.githubusercontent.com, release-assets.githubusercontent.com,
  raw.githubusercontent.com, dl.strem.io). Every request and redirect hop must be https on an allowlisted host
  (`SOURCE_NOT_ALLOWED`, `REDIRECT_NOT_ALLOWED`), at most 3 redirects, 900 s, capped at the declared size and 2 GiB
  (`DOWNLOAD_TOO_LARGE`); the body streams in 64 KiB chunks to a 0600 file inside a registered 0700 `tmp/fetch-XXXXXX/` folder (removed on every path and by the CLI's signal handler, so an interrupt leaves no partial file) with an incremental SHA-256 compared with the
  publisher's (a body whose length differs from the declared size is `SIZE_MISMATCH` and `DIGEST_MISMATCH` is checked next; either deletes the file), then `inspect` runs on it (an unsafe archive fails and nothing is
  recorded) before it is renamed into place. A new version is `approved:false`; `--approve --version <v>` (owner only; `--version` is required) re-hashes and
  re-inspects exactly that stored version offline and marks it approved (`NOT_FETCHED` for an unknown version, `IPA_MISSING`); an upstream digest that
  changes for a stored version is `VERSION_CONTENT_CHANGED`. Takes `.op.lock`. Other codes: `SOURCE_INVALID`,
  `FETCH_NETWORK`, `FETCH_TIMEOUT`, `FETCH_HTTP_ERROR`, `NOT_FETCHED`, `MANIFEST_INVALID`, `MANIFEST_WRITE_FAILED`.
  `HTTPTransport` gains `download(_:sink:)` (chunked, redirect-checked, explicit GET, memory-bounded: the delegate cancels at the size cap at once and suspends the task above 4 MiB unconsumed, resuming at 1 MiB, via `DownloadFlow`; the default throws, as `get` does) and
  `HTTPRequest.bearer` is now optional (`portal` always sets it; `fetch` sends no token). Not built: Feather as a
  source, `--verify` (`sign` refuses an unapproved version: `NOT_APPROVED`).

#### Free team: provision, sign, install and refresh

- Free-team policy (docs/design.md section 18, build step 2). No new command in this step; every paid path is
  unchanged. `Team.paid` / `Team.free` (`Team.id` and `Team.denied`
  keep their paid-path meaning, so `canary`, `export-cert`, `portal`, the ledger and `config.teamId` still return
  `FREE_TEAM_SELECTED` for the free OU). `CertInfo.isFreeTeam` (first OU free, paid OU absent). `CertCheck`
  selects valid free identities by OU only (`FreeIdentity`: SHA-1, fp8, expiry; never a name), `pinnedFree`
  requires exactly the identity named by `freeTeam.certFp8`, and `FreeIdentitySnapshot` with a `Diff`
  (added, removed, unchanged) is the basis for `FREE_CERT_CHANGED`. `sideload doctor` gains one `info`
  row `cert-free` per valid free identity (fp8 and expiry; no row when there is none; the existing rows and their
  order are unchanged). `Config` reads an optional `apps.<alias>.team: "free"` (`appTeam`, `CONFIG_INVALID` for any
  other value; no command uses it) and the `<bundleIdPrefix>.free.*` allowlist (`isFreeBundleId`).
  `Guard.run(context:)` takes `SigningContext.paid` (identical to the existing `Guard.run`) or `.free(FreeSigning)`,
  which requires the free team on `codesign` and in the profile, `application-identifier` exactly
  `6ZU5Z6ZKK7.<id>`, an allowlisted ID, the device in `ProvisionedDevices`, the pinned certificate in
  `DeveloperCertificates`, an unexpired profile (`now < ExpirationDate`; past, equal or missing is `PROFILE_INVALID`), the app actually signed with the pinned certificate (`codesign -d --extract-certificates` into a 0700 scratch directory, removed on every path; the SHA-1 of the leaf must equal the pin, else `GUARD_FAILED`; the subject is never read), no `.appex` in the bundle (a symlink named `*.appex` counts; symlinks are never followed, and one that dangles, loops or resolves outside the bundle, such as a symlinked `PlugIns/`, `Extensions/` or `Watch/`, an absolute target or a `..` escape, is `GUARD_FAILED` naming its relative path; a link resolving inside the bundle, like a framework's `Versions/Current`, is allowed), and the app's own identity agreeing with the caller's bundle ID (`codesign` `Identifier=`, `Info.plist` `CFBundleIdentifier`, and the signed entitlements' `application-identifier` when `codesign` can print them; any mismatch is `GUARD_FAILED`). New codes: `BUNDLE_ID_NOT_ALLOWED`, `PROFILE_INVALID`,
  `PROFILE_CERT_MISMATCH` (also used by `export-cert`), `EXTENSION_REMAINS`; `WRONG_TEAM`, `GUARD_FAILED` and
  `DEVICE_NOT_IN_PROFILE` are reused.
- Free-team devices (docs/design.md section 18, build step 3). `DeviceList` reads each device's transport into
  `ListedDevice.transport` (`network`, `wired` or `unknown`) from `connectionProperties.transportType` (also under
  `properties.connection`, or a `transport` key); `localNetwork`/`network`/`wifi`/`wireless` map to `network`,
  `wired`/`usb`/`cable` to `wired`, anything else or a missing key to `unknown`. The real key is unverified until owner
  spike S1. `device list` gains `transport`, `autoRefresh`, `freeSlotsReserved` and `autoEligible` per saved device.
  Saved devices gain optional `autoRefresh` (default false) and `freeSlotsReserved` (0 to 3, default 0; an
  out-of-range value still loads, so the paid paths and the canary are unaffected, but disables that device's free
  path: `autoEligible` is false, `device auto-refresh --on` is `CONFIG_INVALID`, and `device list` warns; the value
  is read through a validated accessor and changed only through a validating setter, and `device slots` repairs it);
  older configs parse unchanged, unset fields are not written and
  `device save` keeps them on a re-save. New owner-only commands `device auto-refresh --alias <a> --on|--off --yes`
  and `device slots --alias <a> --reserved <0-3> --yes` (`USAGE`, `DEVICE_NOT_SAVED`, `CONFIRM_REQUIRED`; no device
  contact); `device save` rejects `--on`, `--off` and `--reserved` with `USAGE`. `DeviceList.autoEligible(_:listed:)`
  is the pure eligibility rule for the later `refresh --auto` (opted in, paired, link exactly `connected`, transport
  network or wired; a `disconnected` link is not eligible). `DeviceCtl.run` takes a `scope` (`.paid` by default,
  `.free(bundleId:)`) and classifies the argv it will actually send (after `--device` is stripped): for `device install
  app`, `device uninstall app` and `device process launch` it requires exactly one positional and no other non-flag
  word, the free scope requires `Config.isFreeBundleId` (and the positional to match) and the paid scope refuses a
  free-allowlisted ID; an argv with an install, uninstall or launch word in any other shape is refused too. All are
  `BUNDLE_ID_NOT_ALLOWED` before the subprocess. Subcommand words are matched case-insensitively, and a positional
  that is itself `install`, `uninstall`, `launch`, `app` or `process` is refused the same way. The canary's calls
  are unchanged.
- `provision --app <apollo|stremio-ios|stremio-tvos> --device <alias> --yes [--register-device] [--renew]` (docs/design.md
  section 18, build step 5). Owner-run: gets a free-team (6ZU5Z6ZKK7) 7-day development profile for one app on one saved
  device through Xcode, using `CarrierProject`, a one-file multiplatform SwiftUI app (`SUPPORTED_PLATFORMS = "iphoneos
  appletvos"`, `TARGETED_DEVICE_FAMILY = "1,2,3"`, no entitlements or capabilities) written at run time to
  `builds/carrier/` (0700; deterministic, a file already identical is not rewritten; the paid `canary/` project is never
  touched). It runs `xcodebuild -project <carrier> -scheme Carrier -destination id=<udid> -derivedDataPath
  builds/carrier-dd -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=6ZU5Z6ZKK7
  CODE_SIGN_IDENTITY="Apple Development" PRODUCT_BUNDLE_IDENTIFIER=<prefix>.free.<name> build` through the Runner (10 min,
  128 MiB cap), adding `-allowProvisioningDeviceRegistration` only for `--register-device --yes`. `stremio-ios` and
  `stremio-tvos` share `…free.stremio`, `apollo` is `…free.apollo`; the saved device's platform must match
  (`PLATFORM_MISMATCH`). Needs `--yes` (`CONFIRM_REQUIRED`) and takes `.op.lock` (`OPERATION_IN_PROGRESS`). Preflight:
  `KEYCHAIN_LOCKED`; the pinned free identity present, valid and unique, or with no pin exactly one valid free identity
  (`FREE_IDENTITY_MISSING`, `FREE_IDENTITY_AMBIGUOUS`); the App ID budget from the ledger's `freeAppIds` epochs (a bundle ID
  with no epoch under 7 days old is new and needs recent + `freeTeam.reservedAppIds` (default 4) + 1 <= 10, else
  `FREE_APP_ID_LIMIT`). The free identity set is snapshotted before and after the build, also when the build failed: any
  change is `FREE_CERT_CHANGED` (hard stop, nothing stored or pinned, `freeSuspended` recorded in the ledger for the later
  auto-refresh; an unreadable keychain after the build is `IDENTITY_CHECK_FAILED`, the same). The embedded profile is
  decoded with `security cms -D` and must be the free team's, for exactly `6ZU5Z6ZKK7.<bundleId>`, for the device's platform,
  with `get-task-allow`, the device, the pinned certificate and `now < expiry <= now + 8 d`, else `PROFILE_INVALID` naming
  the check. The first success pins the identity (`freeTeam.certFp8` in `config.json`). The profile is copied to
  `profiles/free/<app>/<device>/<uuid>.mobileprovision` (0600) and recorded as `freeProfiles[<device>/<app>]`, with the
  App ID epoch in `freeAppIds`, in `ledger.json` (new optional top-level keys, written only when non-empty; free profiles
  stay out of `profiles`). A repeat must move the expiry by more than 24 hours or it is `PROFILE_NOT_RENEWED` (spike S3).
  `--renew --yes` first moves sideload's own cached profile (regular file, free team, exact app-id, the device's platform;
  never a symlink, another team's, the lab's, atvloadly's or another app's) from Xcode's profile folders into `tmp/`; it is
  owner-approved only if S3 shows Xcode reuses profiles. xcodebuild failures map to `ACCOUNT_NOT_SIGNED_IN`,
  `DEVICE_NOT_REGISTERED`, `FREE_APP_ID_LIMIT`, `DEVICE_LOCKED`, `FREE_IDENTITY_MISSING`, `BUILD_TIMEOUT`, `OUTPUT_LIMIT`;
  anything else is `PROVISION_FAILED` with a redacted `logTail`. Output: `app`, `device`, `bundleId`, `profile{uuid,created,
  expires,daysLeft}`, `file`, `appIdNew`, `appIdsLast7Days`, `identityChanged`, `pinnedFp8`, `pinnedNow`; never a device ID,
  device name, identity name or profile content. New: `Services.xcodeProfileDirectories` (empty by default, so a test that
  forgets it cannot reach the real folders), `Paths.freeProfiles`/`carrierProject`/`carrierDerivedData`, `Config` accessors
  for `freeTeam.certFp8` and `freeTeam.reservedAppIds`, `FreeAppIdBudget`, `ProvisionClassifier`, `ProfileCacheRenewal`.
  The help object lists `provision`.
  A crash-safe in-flight marker (`freeProvisionInFlight` in the ledger, `FreeIdentityGuard.settleInFlight`) is written
  before `xcodebuild` and cleared only with the recorded after-comparison; the next free-team command compares it with the
  current free-OU set first (`FREE_CERT_CHANGED`, or the stale marker is cleared), so an interrupted build cannot let a new
  certificate be absorbed. `--renew` opens each cached profile with `O_NOFOLLOW`, decodes the bytes it read (stdin), re-checks
  device/inode/size/mtime before the move and reports `cachedProfilesMoved` and `cachedProfilesSkipped`. The App ID epoch is counted whenever `xcodebuild` ran; products that cannot be cleared are
  `DERIVED_DATA_NOT_CLEARED`; the profile that is decoded is the profile that is stored.
  `--renew` runs after the derived-data clear (`cachedProfilesMovedTo` holds relative names; `renewScanTruncated` is set past
  1000 files); the moved file's device/inode is checked after the rename (else moved back, counted skipped); the App ID epoch
  is written in the same atomic ledger write as the in-flight marker, before the build. Moving a mismatched file back is
  exclusive (`RENAME_EXCL`), and one that cannot go back stays in `tmp/` as `cachedProfilesStrayInTmp`.
  The carrier's `embedded.mobileprovision` is opened with `O_NOFOLLOW`, must be a regular file of at most 1 MiB, and is read once (those bytes are decoded and stored); a symlink or non-regular file is `PROFILE_INVALID` with check `embedded-profile`.
  The `--renew` result and error model (design section 18): once the renewal has started, every envelope this
  run returns carries all five keys `cachedProfilesMoved`, `cachedProfilesSkipped`, `cachedProfilesMovedTo`,
  `cachedProfilesStrayInTmp` and `renewScanTruncated` (0 when nothing was cut off), plus `app`, `device` and `bundleId`,
  whichever step ended the run and whether it returned or threw; a run before the renewal started, or without `--renew`,
  has none of them and prints byte for byte what it printed before (golden envelopes, `Fixtures/provision-golden/`).
  The outcome is the data, rendered once (no separate copy rides on a thrown error). A move is one
  `renamex_np(RENAME_EXCL)`; across volumes it is refused (`RENEW_CROSS_VOLUME`: `$SIDELOAD_HOME` must be on the same
  volume as `~/Library`), so there is no copy and nothing is ever deleted; a failed move-back, whatever its errno, leaves
  the file in `tmp/` and reports it as a stray. Setup failures (`tmp/` cannot be made) and mid-scan ones
  (`PROFILE_MOVE_FAILED`, `PROFILES_UNREADABLE`) stop the scan and keep what was already moved in the keys. A Ctrl-C or
  SIGTERM during the 10-minute `xcodebuild` still prints the same keys in its `INTERRUPTED` object (`Services.interruptReport`
  registers a report; the handler reads it, which seals the progress so a move can never start after the report). Crash
  safety: before each rename an intent `{from, to, at, state, folder}` goes into the ledger's `freeRenewMoves` (names only:
  `from` is the file's name in the Xcode folder, `folder` a label (`xcode-userdata`, `mobiledevice`), `to` is `tmp/<name>`), is marked
  `done` after the inode check and removed after a successful move-back; a stray is marked `stray`. A finished run's `done`
  entries are removed only after its envelope was fully written to stdout: `Services.postEmit` holds the settlement, the CLI
  runs it from `main.swift` only when `Interrupt.delivered` (no write error, no EPIPE), under the ledger lock, for exactly
  that run's files and never a stray. A kill, a closed pipe or a failed write leaves them. In EVERY `provision` envelope
  (usage, config, device, confirmation, busy lock and the rest) the entries found in the ledger, read once at the start
  without the lock, are reported as `cachedProfilesFromEarlierRun` (`[{from, to, at, state, inTmp, folder}]`, relative
  names only; a duplicate report is acceptable), or `renewRecordUnreadable: true` when the ledger could not be read (parse-level `USAGE` and a failed `ensureHome` included: the CLI
  merges the record where it finalizes any `provision` envelope; and a SIGINT/SIGTERM during any `provision` run, with or
  without `--renew`, carries it in its `INTERRUPTED` object), and
  kept until the owner clears them with `provision --renew-ack --yes` (a ledger edit; no file is touched or deleted). A move whose intent cannot be
  written is not made. New: `ProfileCacheRenewal.Outcome` (never thrown), `RenewProgress`, `InterruptReport`,
  `LedgerFreeRenewMove`.
- `sign --app <apollo|stremio-ios|stremio-tvos> --device <alias> --yes` (docs/design.md section 18, build step 6; free team
  only, the paid `sign` is still not built). Turns the newest approved fetched IPA and the stored free profile for that
  device into a signed `.app` at `builds/signed/<app>/<device>/<Name>.app` (0700 folders), recorded in the ledger's new
  optional `freeSigned[{id:"<device>/<app>",device,app,bundleId,version,sha256Prefix,profileUuid,profileExpires,certFp8,
  signedAt,path,strippedExtensions[{path,bundleId}],droppedEntitlements}]` (written only when non-empty, so a ledger that
  never signed is byte-identical). Order: usage, config (`CONFIG_MISSING`), the saved device and its platform
  (`DEVICE_NOT_SAVED`, `PLATFORM_MISMATCH`), `--yes` (`CONFIRM_REQUIRED`), `.op.lock` (`OPERATION_IN_PROGRESS`), the keychain
  read (`KEYCHAIN_LOCKED`), `FreeIdentityGuard.settleInFlight` before anything else (`FREE_CERT_CHANGED`), then the pinned
  identity (`FREE_IDENTITY_NOT_PINNED`, `FREE_IDENTITY_MISSING`, `FREE_IDENTITY_AMBIGUOUS`). The IPA is the newest approved
  manifest entry for the app (`NOT_APPROVED`, also when nothing was fetched; a newer unapproved fetch is the warning
  `NEWER_VERSION_NOT_APPROVED`), its file must still hash to the manifest's `sha256` (`DIGEST_MISMATCH`, `IPA_MISSING`;
  checked again on the bytes that are unpacked). The device OS is read from `devicectl list devices` through `DeviceCtl`
  (the saved config records none; the output says `deviceOS.source`) and must be at least `inspectMinOS`, or the unpacked
  app's own minimum when the entry has none (`DEVICE_OS_TOO_OLD`; `DEVICE_OS_UNKNOWN` fails closed when it cannot be read).
  The stored profile for device and app must have a ledger record that names exactly the file `provision` writes, be a
  regular file read once without following a link, decode (`security cms -D` on stdin), carry the recorded UUID and pass
  `ProvisionCommand.verify`, the checks `provision` makes (`PROFILE_MISSING`, `PROFILE_EXPIRED` with a fix that says to run
  `provision`, `PROFILE_INVALID` with `check`). The work runs in a registered 0700 `tmp/sign-XXXXXX` folder removed on every
  path (a stale one from a killed run is swept under the lock): `IPAInspector` gained `inspect(path:keeping:)`, the same
  listing, hash, `ditto` extraction, `lstat` walk and report, leaving the unpacked tree in the caller's folder.
  `ExtensionStripper` removes every `*.appex` wherever it sits, then `PlugIns/` if empty (other content kept with the warning
  `PLUGINS_NOT_EMPTY`), all of `Extensions/` and all of `Watch/`, and reports `stripped[{path,bundleId,extensionPoint,
  entitlementKeys,appGroups}]`; an independent re-walk (`ExtensionStripper.remaining`: any `*.appex`, a symlink with that
  name, a root `Extensions/` or `Watch/`, a nested bundle whose Info.plist says watchOS) that finds anything is
  `EXTENSION_REMAINS`. `BundleRewriter` rewrites `CFBundleIdentifier` with `PropertyListSerialization` in the format the plist
  had, removes `_CodeSignature` and the old `embedded.mobileprovision` and installs the free profile's exact bytes.
  `EntitlementReducer` keeps `application-identifier` and `com.apple.developer.team-identifier` (from the profile),
  `get-task-allow` always with the profile's value (the original's is never copied or listed as dropped), and `keychain-access-groups` rewritten to `6ZU5Z6ZKK7.<id>`; everything else is
  dropped and listed in `droppedEntitlements`. A group only a stripped extension used is reported under
  `appGroups.onlyInStrippedExtensions`; one the main app declares (Apollo's `group.com.christianselig.apollo`) is the warning
  `APP_GROUP_DROPPED`, never a stop. `BundleSigner` signs nested frameworks and dylibs innermost first with `codesign -f -s
  <SHA-1> --timestamp=none` (the pinned identity's SHA-1, never a name), then the app with `--entitlements <plist>
  --generate-entitlement-der`, then `codesign --verify --strict --deep` (`CODESIGN_FAILED` with `step`, `KEYCHAIN_LOCKED` for
  a locked key, never the tool's text). `Guard.run(context: .free)` must pass on the result before it is moved into place
  with one `renamex_np` (`RENAME_EXCL`, or `RENAME_SWAP` to replace the previous signed app) and recorded. Output: `app`,
  `device`, `bundleId`, `version`, `build`, `profile{uuid,daysLeft}`, `stripped`, `droppedEntitlements`, `appGroups`,
  `deviceOS{version,minimum,source}`, `warnings`, `sha256Prefix`, `pinnedFp8` and the relative `signed` path; with no minimum OS
  in the manifest or the IPA it fails closed (`MIN_OS_UNKNOWN`), and nested code other than frameworks and dylibs (a nested
  `.app`, `.xpc`, `.bundle` with an executable, a loose Mach-O, or a Mach-O in a framework that is not its own
  `CFBundleExecutable`) is refused before signing (`NESTED_CODE_UNSUPPORTED`, naming the relative path), since it would keep
  its foreign signature; the device-OS check uses the stricter of the manifest's declared `minOS` and the binary's, and a
  declared one counts as known; a failed ledger write after placing the app undoes the placement (`placed: false`; if the
  undo fails, `placed: true`, `recorded: false` and the relative `signedPath`); the stale-scratch sweep runs after `settleInFlight`; never a device
  ID, device name, identity name or profile content. New: `Paths.signedBuilds`, `OSVersion`. `sign` is listed under `built`
  in the help object, so the CLI tests that pinned that list and the two that used `sign` as the not-built example now use
  `install`.
- `install --app <a> --device <d> --yes`, `app remove --app <a> --device <d> --yes` and `slot lend|return` (docs/design.md
  section 18, build step 7; free team only, all through `DeviceCtl`'s free scope, `.op.lock` and `FreeIdentityGuard.settleInFlight`).
  `install` re-checks what `sign` left (the `freeSigned` record, the profile expiry `PROFILE_EXPIRED`, `Guard(.free)` on the signed
  app before the device is touched), takes a `devicectl device info apps` snapshot, applies the slot preflight (a new app needs
  `used < 3`, else `FREE_APP_LIMIT`; a reinstall is slot-neutral, including an app installed by hand with no ledger record; how
  `used` is counted is under Fixed, TestFlight betas), installs, snapshots again and requires the delta to be exactly our ID or none
  (`UNEXPECTED_APP_DELTA`, counts only), and records `installs[]` in the ledger (schema 1, optional, `refresh{}` initialised; a
  manual success clears a suspension). Failures are classified by `FreeInstallClassifier`: `FREE_APP_LIMIT` (installd's
  "maximum number of installed apps using a free developer profile"; the list it carries is reduced to our IDs plus counts and the
  labels WebDriverAgent/SideStore, and widens `used`; the fix says to raise `freeSlotsReserved`), `DEVICE_LOCKED`,
  `DEVICE_NOT_CONNECTED`, `DEVICE_NOT_PAIRED`, `UNTRUSTED_DEVELOPER` (Settings › General › VPN & Device Management),
  `TIMEOUT`, `DISK_FULL`, `INSTALL_FAILED`. `InstallClassifier` (the canary's) also learned `FREE_APP_LIMIT`,
  `UNTRUSTED_DEVELOPER` and `DEVICE_NOT_PAIRED`. `app remove` is owner-only, uninstalls one managed install (the app list must lose
  exactly it), records the uninstall as an op before the device call and marks the install absent only when the snapshot afterwards
  shows the app gone, and warns `LAST_FREE_APP_REMOVED` when no other free-team app would remain. Its printed `slots` are
  `unknown: true` with null counts when the stored `freeSlotsReserved` is out of range.
  `device lendable --alias <d> --app <a>|--none --yes` sets `devices.<d>.lendableApp`. `slot lend --device|--udid --to lab`
  uninstalls it and `slot return` reinstalls it from the `freeSigned` build through the install path (`NO_LENDABLE_APP`,
  `LENDABLE_NOT_INSTALLED`, `ALREADY_LENT`, `DEVICE_NOT_SAVED`, `OPERATION_IN_PROGRESS`; `--udid` only if it matches a saved device
  and is never echoed; a UDID given to `--device` shows as its last four characters). **`install`, `app remove` and `slot lend|return` run on one pending-operation model**
  (`SlotRule`, `SlotBook`, `SlotState`; docs/design.md section 18, which has the full tables). There is one record per
  device and app, `ledger.slots[{id,device,app,presence,lentTo,since,op,seenAt}]` (schema 1, written only when non-empty), where
  `presence` is `present`, `absent` or `unknown` and `op` is the device operation that may still be in flight
  (`{kind: install|reinstall|uninstall, by, startedAt, window}`). `startedAt` is the clock at the moment the op is written, rounded up,
  and the op is written durably BEFORE every device call (install, reinstall, uninstall) with a crash hook at each write;
  `window` is the longest the op can run plus 300 s: 645 s for an install or reinstall, 435 s for an uninstall (the effective
  window is `max(stored, current)`). `installs[].present/opAt` and `lent[]` are a projection of the slots, rewritten in the
  same atomic write as every change, so an older build reads something safe; a ledger from before (`installs[]` + `lent[]`,
  including a stateless `lent`) is migrated under `.op.lock` on first use, once, at point `migrate`, and in memory only for
  `status` and the menu. Every mutating command first runs one gate: if any record on the device has an op inside its window the
  answer is `SLOT_PENDING` {retryAfter, freed:0, uncertain, app, op, state, lent} with no device call (this replaces
  `INSTALL_PENDING`, and it covers a plain install or remove of any app, not only the lent one). One evidence rule settles a record: a
  valid snapshot taken at or after `startedAt + window` (presence comes from it), or, inside the window, only the snapshot taken
  in the same run right after the op, read through a table of 27 cells (op kind x result x that snapshot; docs/design.md). The
  result of a call is unknown on every shape of `FreeDeviceCalls.uncertain`: the runner's kill, devicectl's own `--timeout`
  (a non-zero exit classified `TIMEOUT`), an output overflow, a signal kill, a thrown call, and an exit 0 that does not name the
  bundle. Reaching the op's target state settles an install (present) or an uninstall (absent) even when its result is unknown;
  **a reinstall is never settled by presence alone** (and one that fails definitively with the old copy still listed is `ok:false` with the op's code and `renewed:false`; the slot stays used. A reinstall writes no `installs[]` metadata at W2: the new build's profile, expiry and install date are recorded only when its install succeeded and the snapshot confirms the app, so a failed, unknown, crashed or window-settled reinstall leaves the old copy's entry untouched and the ledger never says it was renewed; the random walk checks that an app's recorded expiry never exceeds the copy on the simulated device), which fixes a reinstall that ended unknown being read as done, then a `lend`
  uninstalling the app and the reinstall landing late. A lend, return, install or remove that ends without a settled result keeps
  its op: the slot reads used and never free (`status`, the install preflight and the menu bar all count a used record whatever its
  state). `slot lend` answers `alreadyLent` with no device call only when the lab holds the slot; otherwise it settles
  first (`UNINSTALL_RESULT_UNCERTAIN`, `RETURN_NOT_LANDED`, or `SLOT_STATE_UNKNOWN` when the device cannot be read). `slot return`
  claims nothing without a snapshot that lists our ID (`RETURN_FAILED` with `cause`, `state`, `lent`, `uncertain`, `retryAfter`;
  `settled:true` when a `returning` record turns out to have landed; a confirmed return with an unexplained app-list change is
  `UNEXPECTED_APP_DELTA` with `returned:true`); nothing lent is an ok no-op. `slot lend` refuses before uninstalling without a
  valid, unexpired signed build (`NOT_SIGNED`, `PROFILE_EXPIRED`), warns `LAST_FREE_APP_REMOVED`, and an uninstall that reports
  success while the app is still listed is `UNEXPECTED_APP_DELTA` with the op kept and nothing claimed. A snapshot is evidence only
  if it is a complete listing (`info.outcome` success, `result.apps` an array of objects with a non-empty `bundleIdentifier`);
  anything else is `SNAPSHOT_FAILED`. A lent slot counts as used for a new install; a hand-installed own ID is a slot-neutral
  reinstall and is recorded present. A plain `install` of a lent app is `APP_LENT`. `status` gains `lent[{app,device,to,state,since,holds}]`,
  `slots.devices[{alias,limit,used,free,reserved,apps[],lent,pending,retryAfter}]` (every used record counts once; a pending
  record is never free and adds the warning `SLOT_STATE_PENDING`) and `appIdsLast7Days`, from the ledger and config only (no
  devicectl). The lab-facing JSON changes only by addition: `slot lend` and `slot return` may now answer `SLOT_PENDING` because of
  a pending plain install, reinstall or remove on the device, its data gains `op` and its `state` may be `pending`, and
  `slots.devices[]` gains `retryAfter` and `unknown` (true when `ledger.json` is unreadable, or for a device whose stored `freeSlotsReserved` is out of range: `used`/`free`/`apps`/`lent`/`pending` are then null, top-level `lent` is null, and the menu shows "slots unknown"); codes, `lent[].state` and `holds` are unchanged. `LAST_FREE_APP_REMOVED` warns unless one of
  our other installs or a WebDriverAgent/SideStore app remains; `DEVICE_NOT_PAIRED` has a generic fix shared with the canary. The
  menu bar app shows a pending or lent slot as used, never free (the union of the signed apps and the slot records). A legacy
  `installs{present:false, opAt}` migrates as pending too. The free-team text patterns added to `InstallClassifier`
  (`FREE_APP_LIMIT`, `UNTRUSTED_DEVELOPER`, `DEVICE_NOT_PAIRED`) are read only for `Input.freeTeam` (set by `FreeInstallClassifier`),
  so the paid canary's codes are unchanged.
  Tests use a simulated app list behind a fake runner, the real installd failure text as a fixture
  (`Fixtures/install-free-app-limit.json`), and assert no UDID, CoreDevice ID or device name in any output and that WebDriverAgent's
  and atvloadly's IDs are refused at every entry point. `SlotRuleTests` pins the 27 cells against an independent copy of
  the design, rule (i) at its boundary (one second before the end keeps, the end settles) and every migration row; `SlotCellMatrixTests`
  drives every cell through every command that issues its kind of op (install, reinstall, return, lend, remove) with every
  unknown-result shape (runner kill, devicectl's own timeout, overflow, signal kill, a thrown call, an unnamed success), checking the exact
  device calls, the record, the output and the gate; `SlotMatrixTests` runs the per-command outcome rows and every invalid
  snapshot shape; `SlotCrashTests` injects a crash after each durable write (`migrate` and `{install,lend,return,remove}.{settle,intent,final}`
  through `Services.afterDurableWrite`, a test hook) from every starting record; `SlotGraceTests` covers a late install after a timed-out
  return, a late uninstall after a timed-out lend, a killed return, and the two regressions (a reinstall that ends unknown, then a lend,
  then the late landing; a lend while another app's install window is open); `SlotMigrationTests` reads today's ledger shapes
  (including a stateless `lent`); and `SlotWalkTests` runs 20 seeded walks of 500 steps over every command with random faults,
  crashes, clock jumps and late landings, checking invariants I1 to I9 against the simulated device after every step and again once
  everything in flight has landed (reverting either fix makes it fail on every seed).
- `filler`, a fourth app key for `provision`, `install`, `app remove`, `slot` and `device lendable` (docs/design.md section 18):
  a tiny app with no IPA, so the install and slot paths can be exercised without a fetch. `provision --app filler --device <d>
  --yes` builds the carrier as before, copies the Xcode-signed `Carrier.app` with `ditto` into a scratch folder, runs the
  free-team guard on the copy, places it at `builds/signed/filler/<d>/Carrier.app` in one rename and records `freeSigned`
  (version `1.0`) in the same ledger write as the profile (a failed write puts the previous app back); a failed guard
  records and places nothing. Output gains `signed`. It uses one App ID of its own and, once installed, one managed slot.
  `sign --app filler` is `USAGE`; `device lendable` may name it (owner-only); nothing is lendable by default.
  Every "sign it again" fix (`install`'s `NOT_SIGNED`, `PROFILE_EXPIRED` and guard failures, and the `RETURN_FAILED` fix of
  `slot return`) comes from one helper, `ProvisionApp.resignSteps`, which says `provision` only for the filler and
  `provision` then `sign` for the others; `sign`'s usage text no longer lists the filler.
- `SIDELOAD_TEST_FORCE_SLOT` for `slot lend|return`, in debug builds only (`#if DEBUG`, compiled out of release): `pending`
  answers `SLOT_PENDING` and `return-failed` answers `RETURN_FAILED` (`slot return` only), with no lock, ledger or device, so
  mobile-safari-lab can test its handling without a device; `return-failed` on `slot lend` and any other value are `USAGE`.
  `scripts/check.sh` now builds the release CLI and fails if the variable's name is in the binary or the binary honours it.
- `refresh --device <d> [--app <a>] [--within 1-6 | --force] --yes` (docs/design.md section 18, build step 9, manual part), free team
  only and owner-run: renews the installs on one saved device that have `--within` days or fewer left (default 5; `--force` is
  6, the ceiling, since a renewal must move the expiry by more than 24 hours) by running the existing `provision`, `sign` and
  `install`, soonest expiry first. Candidates are `installs[]` plus an app installed by hand that has a signed copy and that the
  device shows (its device expiry is unknown, so its install, which records it, is always done; provision and sign run first only
  if the signed copy is within the window); an app the device does not show is `NOT_PRESENT` and is never put back, and a slot lent to the lab gets provision
  and sign only (`renewed-not-installed`, also its ledger `lastResult`; warning `APP_LENT`, no device call). A cancelled run is `ok:false` with `INTERRUPTED`. No new App ID: `provision` runs without `--renew`
  and only a `PROFILE_NOT_RENEWED` is retried once with it (never `--register-device`); each app reports `appIdNew` and
  `appIdsLast7Days`. A rerun after a partial failure resumes (provision skipped when the stored profile already moves the expiry
  by more than 24 h, sign when the signed copy carries it). Read-only stops with no work: a ledger `freeSuspended`
  (refresh never clears it) and `SLOT_PENDING` (+ `retryAfter`; each install gates again). Each step takes `.op.lock` itself
  (`OPERATION_IN_PROGRESS` per app, never waited on). A fatal code stops the run and skips the rest; `DEVICE_LOCKED`,
  `DEVICE_NOT_CONNECTED` and `DEVICE_NOT_PAIRED` skip only the installs (provision and sign still run, the rerun resumes at the
  install). A manual run is not held back by the daily caps (2 per install, 4 per device, per local day) or by a suspension: it
  warns, counts the attempt, and a success clears the suspension. Writes only the install's `refresh{}` fields (attempt before
  the first step; result, failure count, 30 m to 12 h `nextEligible`, `suspended` after); never `slots`. One object:
  `results[{app, status, steps, code, daysLeftBefore, daysLeftAfter, appIdNew, appIdsLast7Days, renewRetried}]`, counts,
  `warnings`; `ok:false` iff an app failed. `--auto` and `--print-agent` are `USAGE` (not built).
- `PostEmit.add` chains registrations so two `provision --renew` runs in one process (`refresh`) both settle their ledger record
  after the envelope is written; `provision` uses it in place of `set`.

#### App data for lent slots

- App-data backup on `slot lend` and restore on `slot return` (docs/design.md section 18, "App data"), Apple tools only
  (`devicectl device info files`, `copy from`, `copy to`). Before the durable intent and the uninstall, `lend` saves the lent
  app's data container (files only, `Library/Preferences` first, not `Library/Caches` or `tmp`; at most 200 files, 256 MiB and 120 s of wall time, Runner grace included; unsafe or colliding listing paths are dropped and counted failed before any filesystem call; no link is ever followed or left in a backup) to
  `$SIDELOAD_HOME/backups/<device>/<app>/<stamp>/` (directories 0700, files 0600, a manifest with SHA-256 hashes, tied to the
  lend by its `since`). After the confirmed install and before the success JSON, `return` pushes the backup of that lend back
  (re-hashed first, 120 s), relists and compares; only a full match marks it restored. Neither is a slot operation, the slot
  model is unchanged, and neither can fail the command: a lend that cannot back up proceeds with `dataBackedUp:false` and a
  `DATA_BACKUP_FAILED` / `DATA_BACKUP_INCOMPLETE` warning, a failed restore is a `DATA_RESTORE_INCOMPLETE` /
  `DATA_RESTORE_UNVERIFIED` / `DATA_RESTORE_PARTIAL_BACKUP` warning with the backup kept. The newest 2 backups are kept per
  device and app. `apps.<app>.backupData` (default true) turns it off per app. The lab contract only grows: `lend` gains
  `dataBackedUp`, `dataFiles`, `dataFilesFailed` (and `dataBackupSkipped`), `return` gains `dataRestored`,
  `dataFilesRestored`, `dataFilesFailed` (counts and booleans, never a path or file name); the new codes are warnings only.
  Allow the lab up to about 2 more minutes per call. Backups are secrets-class (session tokens): `check-secrets` refuses a
  `backups` path segment and AGENTS.md says so. The `DeviceCtl` allowlist gained exactly three argument shapes (free scope,
  `appDataContainer` for the scoped `<prefix>.free.*` app only, relative device paths, local paths under `backups/`), with a
  Sources scan test. **The restore (`copy to`) was first checked live on 2026-10-25 (mobile-safari-lab#63, Stage 2: an iPhone on Wi-Fi, stremio-ios, a backup of 11 of 13 files; after the return the app was still signed in with its library and add-ons).** The owner-only `slot restore` (below) retries a
  failed or crashed restore.
- The backup manifest gains an optional `supersededAt`: `slot lend` marks every older, unrestored backup of the app superseded
  (whether or not the new lend saved a backup), so `slot restore` never pushes data from an earlier lend. Older manifests
  without the key still read. It gains an optional `uninstalledAt`, set wherever a snapshot shows the app off the device while the slot
  is lent (the lend's confirmed uninstall; a later lend that finds the app gone and records the slot lent; the return that finds
  the app gone, before its install, so a return that stops before its own restore still leaves the backup to `slot restore`): `slot restore` pushes only a backup that has it, so a lend that saved a backup and
  then failed to uninstall (the app and its live data stay) can never be restored over newer data; such a backup answers
  `NO_PENDING_RESTORE` with `notUninstalled:true`. Backups from before the field are not restorable by `slot restore` (the return
  still restores its own lend's). The `NO_PENDING_RESTORE` booleans are each set on their own (a superseded backup that also
  lacks the mark reports both). Before any device call the folder chain is walked from the backups folder one part at a time
  with `lstat`, and every manifest entry's local file must be a readable regular file under real folders: anything that
  cannot be read, listed or `lstat`ed, or a link at any level (the device's or the app's folder, a backup folder, the
  manifest, `data/` or any folder or file an entry points into, dangling or not), is `unreadable`, never "no backup", and
  nothing behind it is followed. Only a real folder chain that stops at a missing part is "no backup". `slot lend` takes its `since` for the backup, the
  supersede and the mark from the settled ledger record, not the one read before the settle (which could be a lend the settle
  undid).
- `slot restore --device <alias> [--app <app>] --yes` (docs/design.md section 18, "App data"), owner-only: the retry of an
  app-data restore that `slot return` did not finish. `--app` defaults to the device's lendable app; `--udid` and `--to` are
  `USAGE`. Not a slot operation: no ledger write, no install or uninstall. Order: usage, saved alias, app, `--yes`
  (`CONFIRM_REQUIRED`), `.op.lock`, the marker and keychain, the gate (`SLOT_PENDING`), `ALREADY_LENT` when the app is lent,
  the pending backup (a local read; `NO_PENDING_RESTORE` with `restored`, `superseded`, `unreadable`, `notUninstalled` booleans), one app-list
  snapshot that must list the app (`SNAPSHOT_FAILED`, `APP_NOT_INSTALLED`), then the same push, relist and compare as `return`
  (one 120 s allowance). Success prints `dataRestored:true`, `dataFilesRestored`, `dataFilesFailed` (and warnings); anything
  not fully verified is `RESTORE_FAILED` with `cause`, `dataRestored:false`, the counts and `kept:true`. The backup is kept
  either way and a rerun is safe. Only the newest finished backup is considered. New codes: `NO_PENDING_RESTORE`,
  `APP_NOT_INSTALLED`, `RESTORE_FAILED`. Counts and booleans only; the `DATA_RESTORE_*` warnings of `slot return` now name the
  command, with the `--device` and `--app` to retry, in their `fix`. `slot restore` itself has not been run on a device yet.
- `slot` takes `--app` and `--yes` for `restore` only; `lend` and `return` answer `USAGE` if given either.
- Per-reason failure counts for the app-data backup (dividedby/sideload#2; the lab's Stage 2 runs skipped 1 to 2 of 12 to 13 files
  with no way to tell why). `slot lend`, `slot return` and `slot restore` gain `dataFailures` when `dataFilesFailed` is above 0: an object of the non-zero counts by
  reason, absent when nothing failed, whose values always sum to `dataFilesFailed`. Reasons (fixed words, never a path, file name or
  text from `devicectl`): `unsafePath`, `nameCollision`, `fileCap`, `sizeLimit`, `timeLimit`, `localError`, `notRegularFile`,
  `sizeMismatch`, and for the `copy from` call `copyTimeout`, `copyDeviceLocked`, `copyDeviceNotConnected`, `copyNotRun`,
  `copyNoResult`, `copyOther`, and for the restore also `notOnDevice` (pushed, but the relisting did not show it); the restore counts its refusals before the call as `unsafePath`, `localError` and `timeLimit` (the call's class is best effort: the locked and not-connected patterns are loose; `devicectl`'s numeric error codes
  are not reported). The progress line gains the same counts: `app data backup: 10 file(s) saved, 3 failed (copyTimeout 2,
  notRegularFile 1)` and `app data restore: ... failed (...)`. Additive: `dataBackedUp`, `dataFiles`, `dataFilesFailed` keep their meaning.

#### status and the menu bar app

- `status` (v1): read-only, file-only snapshot for the menu bar (no subprocess, keychain, device, portal or network).
  Prints `state` (worst of `ok`, `blocked`, `warn`, `critical`, `unknown`; expiry outranks `blocked`, expired is
  `critical`; only a last canary run of `working` is `ok`; `error`, `skipped` or any other status is `unknown`), `canary` (from `logs/canary.jsonl`), expiry `items` (shared with `ledger`), `ledger{updated,present}`,
  `devices` (IDs as the last four characters, `visibility` always `unknown`), `apps` (alias names) and `warnings`. A
  corrupt ledger, config or canary log is a warning with an empty section, not a failure. `--notify`, `--print-agent`
  and `--warn-days` answer `USAGE` (`--warn-days` is dropped: the 60 and 14 day thresholds stay fixed).
- `SideloadMenu`, the menu bar app (docs/design.md section 12; v1 is read-only plus safe actions), and `scripts/make-app.sh`,
  which builds `.build/app/SideloadMenu.app` (arm64 release build, `Info.plist` with bundle ID
  `io.github.dividedby.sideload.menu` and `LSUIElement`, the canary project under `Resources/canary/`, ad-hoc
  `codesign -s -`, then `codesign --verify`); it never installs or launches the app. A 360 pt window-style `MenuBarExtra`:
  a countdown-ring icon (owner decision 2026-10-24: the ring is the time left of the soonest free install over 7 days, drawn
  clockwise from 12 o'clock in the label colour, orange when due, red when critical; a dashed red ring and cross when
  expired; a solid red ring and "!" when the ledger's `freeSuspended` is set; a dashed grey ring and "?" with no data;
  blue for renewing and a red cross badge for a failed renewal, both modelled but set by nothing yet;
  worst wins; the paid state drives it only with no free installs, as a full ring (ok, due, critical or unknown); modelled in `MenuIcon` and drawn in
  `StatusIcon`), a "Check status now" button, a one-line free/paid strip
  from the last canary run, and an Apps card per saved device (status dot, alias, Wi-Fi/USB/offline, free slots, per-app
  days left with a 7-day time-left bar that is green, orange when due and red when expired, reserved slots as grey rows,
  one "Seen N h ago" line for an offline device (the header already says offline); auto-renew state stays hidden behind `MenuInputs.autoRefreshAvailable`, which nothing sets yet). Free installs use ok above 3 days, due at 3 or fewer, critical at 1 or
  fewer. Run doctor shows inline (in process through `Doctor.run`), Settings… opens `config.json`, Open ~/.sideload, Quit.
  "Renew…" and the cert kit Export are visible but disabled (the menu runs neither `refresh` nor `export-cert` yet). Loads at launch, on panel
  open and on demand; no timers. The model is UI-free in `SideloadCore/Menu/` (`MenuSnapshotBuilder`, `FreeInstallExpiry`,
  `MenuLoader`, `DoctorSummary`) with Swift Testing tests; `SideloadMenu` holds only views and the view model.
- `ListedDevice.lastConnection`, read from devicectl's `connectionProperties.lastConnectionDate` (the menu bar's "Seen N h ago").
- `status` free-install expiry and pending restores (docs/design.md section 18, build step 8 without `--notify`). `items` gains one
  `kind: install` item (`<app> @ <device>`) per free install recorded on a device still saved in config, at its profile's expiry,
  with the free levels (`warn` at 3 days or fewer, `critical` at 1 or fewer, then `expired`), so `state` follows them; `ledger`
  still prints the paid items only. New `installs` (`{id,device,app,notAfter,daysLeft,level,autoRefresh,lastResult,nextEligible,suspended}`)
  and `pendingRestores` (`[{device,app}]`: a backup `slot restore` would push, never while the app is lent or the device has an
  operation inside its window, nor within 5 minutes of the slot's last snapshot, because `slot return` records the slot before it
  pushes the data), both null when the ledger or the config cannot be read. New warnings: `INSTALL_EXPIRING` and
  `INSTALL_EXPIRED` (fix: the owner's `refresh --device <d> --app <a> --yes`) and `DATA_RESTORE_PENDING` (fix: the owner's
  `slot restore --device <d> --app <a> --yes`; it does not change `state`). The menu bar app shows the pending-restore warning as
  a notice. `status` now also reads the backups' manifests (no lock, no subprocess, no write; the saved data is never read and
  output is aliases, app names, dates and counts only). Additive for the lab: no existing field changed meaning, but free installs now feed `state`:
  it can be `warn` or `critical` from one, and with no canary run a healthy one makes it `ok` (not `unknown`), so `ok` no
  longer implies a working canary; read `canary.last` for that.

### Changed
- CI uses fewer Actions minutes. A new push to a PR cancels the run still going for its older commit (`concurrency`,
  never on `main`), and the job has `timeout-minutes: 5`, so a hung run can't bill hours.
- `install` no longer answers `NOT_IMPLEMENTED`; `help` lists `install`, `app` and `slot` as built. The signal test that used
  `install` as an immediate command uses `help`.
- Docs only, no code: rules and design for owner-approved free-team (6ZU5Z6ZKK7) signing as an interim route
  (owner decision 2026-10-23; build order in `docs/design.md` section 18). `AGENTS.md` replaces "leave the free account alone" with a narrow-use
  rule (the pinned existing identity, App IDs and 7-day profiles only for `io.github.dividedby.free.*`, never a new,
  revoked or exported certificate, never another bundle ID, mobile-safari-lab, atvloadly or the `atv` VM), documents
  `$SIDELOAD_HOME/.op.lock` as the lock shared with mobile-safari-lab (dividedby/mobile-safari-lab#63, sideload #2),
  updates the Apple TV section, and adds `provision`, `refresh`, `app remove`, `--register-device`,
  `device auto-refresh`, launchd bootstrap and the slot/App ID budgets to "Ask the owner first".
  `docs/design.md` drops "free teams are unsupported", adds the 2026-10-23 decisions to section 2, makes the guard
  context-parameterised (section 10), replaces the wrong "first asset" Apollo rule with an exact-name selector
  (`Apollo-Reborn-<ver>-GLASS-NOEXTENSIONS.ipa`), approves the Stremio iOS index, resolves open question 1 (CLI at
  `~/.local/bin/sideload`), and adds section 18 (free team: pinned identity, allowlist, extension stripping, 3-app
  and 10-App-ID budgets, auto-refresh by Wi-Fi or USB with caps, backoff, suspend and a kill switch, `app remove`,
  the Apple TV takeover checklist, build order and owner spikes). `README.md` records the free team as an interim
  route, the owner-driven Apple TV takeover, and the free-team commands as planned (they are built later in this
  release; see Added).
- Internal: the `check-secrets` test and script give every child process a 30 s timeout with `SIGKILL`, so a hung
  child fails with a named error. `scripts/check.sh` tees `pnpm test` output to `$TMPDIR/sideload-pnpm-test.log`
  (outside the repo) and prints the path on failure, to catch a once-seen "Promise resolution is still pending" cancel.
- Internal: the `blockedStdoutMainWrite` signal test waits for a DEBUG-only readiness marker (`SIDELOAD_TEST_READY`,
  written after the handlers are installed) instead of sleeping 500 ms, and signal tests report `terminationReason`
  and `terminationStatus` on failure; `scripts/check.sh` also tees `swift test` to `$TMPDIR/sideload-swift-test.log`.
- Internal: `RunnerTests` timing checks no longer fail on a loaded machine. They timed the whole `await run`, which also
  counts how long the test task waits to be resumed; under load the overflow test took 16 to 22 s against a 15 s bound.
  Instrumented next to 16 CPU burners, the runner had sent its last signal 57 ms after the spawn, and the test task resumed
  11 s later. The timing checks now compare marks taken on the runner's own thread (the spawn and each signal sent): at least
  the timeout or grace period, and at most that plus a 5 s slack. The overflow test also proves more than before: its fixture
  died of SIGPIPE when the runner closed its pipes, so it passed even with the grace-period SIGKILL removed. The fixture now
  ignores SIGTERM and SIGPIPE and keeps running, and the test checks the child ended by SIGKILL, sent one grace period after
  SIGTERM. The runner is unchanged.

### Fixed
- App-data backup and restore treated a `devicectl` call that exits 0 but reports a failure as a success. A call now fails
  when its document is not an object, has a top-level `error`, has an `info` that is not an object, or has an `info.outcome`
  other than `success`. A `copy from` that did so and left no file was taken for a folder (counted nowhere); one that left a
  regular file of the right size was counted saved, and is now counted failed (the file is removed); a `copy to` that did so
  was counted pushed and caught only if the relisting disagreed. Each is now a failed file (`dataFilesFailed`, and the
  `DATA_BACKUP_*` / `DATA_RESTORE_*` warnings follow from it). A backup in which every copy fails this way is now
  `DATA_BACKUP_FAILED` with no backup, not an empty complete one. A `copy from` that exits 0 and leaves nothing on this Mac
  for a listed file is now a failed file too (`copyNoResult`), where it used to be counted nowhere. The listing calls run
  the same check before `parseListing`, so a listing with a top-level `error` (a null one is none) or an `info` that is not
  an object is now refused as well, where `parseListing` alone accepted it: the backup is `DATA_BACKUP_FAILED`, a restore
  relisting is `DATA_RESTORE_UNVERIFIED`. An exit 0 with no document, or with neither `info.outcome` nor `error`, is still a
  success (the callers check the file left, or relist). Counts only; no output field changes meaning.
- The live free-slot count no longer counts TestFlight betas (mobile-safari-lab#63): `devicectl device info apps` marks them
  `builtByDeveloper` like free-team apps, so the owner's iPhone read `used: 8` and the filler install and every `slot return`
  would have stopped with `FREE_APP_LIMIT`. Other free-team apps are now found by one read-only `devicectl device profile list
  --type provisioning` per command (an installed, non-managed app with a `6ZU5Z6ZKK7` profile for its bundle ID; expired
  profiles count, stale ones for absent apps do not; strict parse, and no code path ever calls `profile install|remove|validate`,
  with a scan test). The lab's WebDriverAgent counts inside the slot lent to it: `unmanaged = max(freeSlotsReserved, otherNonLab +
  max(lent, labApps) - lent)`, `used = managed + unmanaged + lent + pending`. If the profile read fails or is malformed the count is
  `managed + freeSlotsReserved + lent + pending`; installd's `FREE_APP_LIMIT` is the backstop. Every `slots` object (`install` and its `FREE_APP_LIMIT` errors, `slot return`, `app remove`) now comes from one builder and has the same keys: `limit`, `used`, `free`, `reserved`, `managed`, `unmanaged`, `lent`, `pending`, `otherDeveloperApps`, `otherFreeTeamApps`, `labApps`, `otherNonLab`, `profilesRead`
  (counts only); `unmanaged` now follows the formula. The preflight message names its basis. No change to the allowlist,
  `.op.lock`, the slot record model, `status` or the menu.
- Evidence bundle, after the first real run: the CoreDevice error's domain (`com.apple.dt.CoreDeviceError`) was
  dropped because a short subject word can sit inside it; four known Apple error domains are now kept exactly
  (the verifier has its own copy of the list), other domains keep the subject check. stderr lines with no
  letter or digit (separator rules) are dropped silently instead of being emitted. `evidence.txt` gets a blank
  line between the header paragraph and the first `key: value` line.

## 0.1.0 - 2026-10-20

0.1.0 predates this repository's public history; its tag is not in this repository.

### Added
- Issue conventions: `docs/agents/` (issue tracker, label convention, Idea Inbox protocol), the
  `## Issues` section in `AGENTS.md`, and the Idea Inbox issue (#1).
- Repo scaffolding: `.gitignore`, `package.json` (zero dependencies), CI workflow.
- Secrets guard: `scripts/check-secrets.mjs` (`--staged` / `--all`) and a pre-commit hook that blocks
  certificates, keys, provisioning profiles, IPAs, device UDIDs (including IDs saved in `$SIDELOAD_HOME`)
  and `.p12` password assignments.
- `AGENTS.md` with the project rules for agents.
- Research notes in `docs/research/`: Feather on-device signing, Apollo Reborn / Stremio requirements,
  tvOS install via `devicectl` and atvloadly coexistence, Development vs Ad Hoc profiles.
- `docs/research/stremio-source.md`: owner-approved Stremio for Apple TV source (third-party index of
  Stremio's official CDN builds), URL allowlist and digest handling.
- `docs/design.md`: CLI design (commands, state layout, modules, canary flow).
- CLI skeleton `bin/sideload.mjs` (one JSON object per invocation, exit 0 iff ok) with `doctor`,
  `device save|list` and `canary`; unbuilt commands return `NOT_IMPLEMENTED`.
- `doctor` checks: Xcode, command-line tools (`codesign`/`clang`/`swiftc` via `xcrun`), paid-team
  certificate by OU + expiry, saved iPhone visibility (fails when `devicectl` cannot list devices),
  Apple TV pairing state (info), free disk space.
- `canary/` committed SwiftUI project (iOS 17, no entitlements; team and bundle ID passed at build time).
- Test suite under `test/` (`node --test`) with fixture devicectl/openssl output.
- `docs/design.md` records the target architecture: a native arm64 Swift package (core + JSON CLI +
  SwiftUI menu bar app); the Node CLI is the tested reference until the Swift port reaches parity.
- Swift port, step 1: `Package.swift` (Swift 6 mode, macOS 27, zero dependencies), `SideloadCore` with the
  `Output/` module (`JSONValue`, `Envelope`, `Redactor`, `SideloadError`, single-write `Emitter`) ported from
  `src/output.mjs`, a stub `sideload` executable (every command returns `NOT_IMPLEMENTED`), Swift Testing
  suite `OutputTests`, and the local gate `scripts/check.sh`. Swift output sorts keys and does not escape `/`.
  The Node CLI remains the working implementation.
- Swift port, step 2: `Exec/` ported from `src/exec.mjs` (`CommandSpec`, `RunResult`, `Runner`,
  `PosixSpawnRunner`, `LiveChildren`): `posix_spawn` into its own process group, one `poll(2)` thread per run,
  mandatory timeout, combined output cap, SIGTERM then SIGKILL escalation with a final group sweep, Task
  cancellation. The CLI now handles SIGINT/SIGTERM/SIGHUP (kills live groups, emits one `INTERRUPTED`
  object, exits 128+signo) via `Interrupt`, the single gate that owns stdout and the process exit, and
  `DispatchSource`s. Tests: `RunnerTests` (real-process
  fixtures), `FakeRunner` for later modules, signal tests that run the built `sideload` binary. `DeviceCtl`
  moves to the Config step (`docs/design.md` section 14).
- Swift port, step 3: `Config/` ported from `src/config.mjs` (`Paths`, `Config` with unknown fields preserved,
  `ConfigStore`, `OperationLock`) and `Exec/DeviceCtl` ported from `exec.devicectl`. `$SIDELOAD_HOME`
  resolution, 0700/0600 modes, `HOME_IN_GIT_WORKTREE`, `CONFIG_INVALID`/`FREE_TEAM_SELECTED`, atomic writes
  (`<file>.<pid>.<rand>.tmp`, `O_EXCL`, fsync, rename), `ConfigStore.update` under a `flock` on
  `.config.lock` (5 s bounded retry, then `BUSY`), `.op.lock` (`OPERATION_IN_PROGRESS`). `DeviceCtl` resolves
  aliases, accepts only saved IDs, owns `--timeout`/`--json-output`, chmods its randomly named output file to 0600 and deletes it on every
  path. Tests: `ConfigTests` (including lock tests) and `DeviceCtlTests`.
- Swift port, step 4: `Classify/` ported from `src/classify.mjs` (`InstallClassifier`, `BuildClassifier`: pure,
  same codes, reasons and fix strings as Node; 0xe8008018 in hex, signed and unsigned forms is `blocked`) and
  `Devices/` ported from `src/devices.mjs` (`DeviceList.parse` for `devicectl list devices` jsonVersion 5 with the
  deprecated-key fallbacks, `findCandidates`, `findSaved`, `visibilityOf`). Tests: `ClassifierTests` and
  `DeviceListTests`, with the 11 `install-*.json` fixtures copied verbatim into `Tests/SideloadCoreTests/Fixtures/`.
- Swift port, step 5: `Keychain/` read path ported from `src/certs.mjs` and `src/checks/cert.mjs`: `KeychainClient`
  (read-only protocol), `SecurityKeychain` (Security.framework: `SecItemCopyMatching` for identity references,
  `SecIdentityCopyCertificate`; no private-key access, so no prompts), `CertificateReader` (OU, `notAfter` and the
  Apple Development flag via `SecCertificateCopyValues`, which the macOS 27 SDK spike confirmed; no `openssl`),
  `CertInfo`, and the pure `CertCheck` (paid team matched on OU only, other teams reported as info, the
  deny-listed free team never selected, expiry days, warn under 60). Like Node's `find-identity -v`, only valid
  identities count: `CodeSigningTrust` evaluates `SecTrust` with the code-signing policy, offline. Tests: `KeychainTests` with `FakeKeychain`
  and embedded throwaway self-signed public certificates, plus an opt-in real-keychain test
  (`SIDELOAD_REAL_KEYCHAIN=1`, read-only).
- Swift port, step 6: `Checks/` (`xcode`, `clt`, `cert`, `device`, `appletv`, `disk`: same ids, severities, messages and
  fix strings as Node, subprocesses only through the injected `Runner`) and `Commands/` (`Doctor`, `DeviceCommand` for
  `device save|list`, and `Services`: runner, filesystem, clock, keychain and home). `CertCheck` moved into `Checks/`
  and its result type is now the shared `CheckResult`. The Swift CLI now runs `doctor` and `device save|list` through a
  hand-written `ArgParser` (per-command options, `--opt value`, `--opt=value`, flags, `-h`; bad input is `USAGE`); the other
  commands still answer `NOT_IMPLEMENTED`. Tests: `DoctorTests` (all 23 `doctor.test.mjs` cases), `DeviceCommandTests`,
  `ArgParserTests`, `CLITests`. Differences from Node are listed in `docs/design.md` section 14. `doctor` and `device list` on the real Mac
  match Node.
- Swift port, step 7: `Commands/Canary` ported from `src/commands/canary.mjs` (preflight cert + device, app snapshots
  before and after, the pinned `xcodebuild` Debug build with a 10 minute timeout and 128 MiB output cap, the
  pre-install guard, `devicectl device install app`, classification, one scrubbed install JSON on the first non-working
  run, uninstall only of the exact canary id and only if this run added it, `unexpected-app-delta` warning,
  `logs/canary.jsonl`) and the `Guard` type (`codesign -dvv` team, `security cms -D` profile parsed with
  `PropertyListSerialization`, team and `ProvisionedDevices` checks). The run holds the operation lock
  (`OPERATION_IN_PROGRESS`). `Services` gains `log` (progress to stderr and `logs/commands.log`, redacted) and
  `canaryProject`. The Swift CLI now runs `sideload canary --device <alias> --yes [--keep]`; help lists it as ported.
  Tests: `CanaryTests` (all 32 `canary.test.mjs` cases plus lock, log and CLI cases), `CanaryGuardTests`,
  `CanaryScrubTests`, and `CanaryParityTests`, which compares 36 scripted scenarios with golden envelopes recorded
  from the Node canary. All tests use fakes: nothing ran `xcodebuild`, `devicectl`, the portal or the real device.
  `LoggingRunner` logs every subprocess of the live CLI to `logs/commands.log` (`exec <file> <args>`, redacted), as Node did.
  Differences from Node are listed in `docs/design.md` section 14.

### Changed
- The Swift CLI is the implementation. Node remains only for the secrets hook (`scripts/check-secrets.mjs`) and
  its test; `package.json` is reduced to the hook scripts and `test` runs the check-secrets suite only. The
  `engines` floor is dropped (CI still runs Node 22). Unbuilt commands (`export-cert`, `fetch`, `sign`,
  `install`, `status`) answer `NOT_IMPLEMENTED` with a fix pointing at `docs/design.md`.
- README, AGENTS.md and `docs/design.md` describe the Swift-only layout; Swift comments no longer cite the
  Node sources.
- `docs/design.md`: goals state that only paid Apple Developer accounts are supported (free teams refused); section 4
  embeds the canary project in the menu bar app bundle.
- `docs/design.md` revised for the Swift architecture: SPM package (`SideloadCore`, `sideload` CLI,
  `SideloadMenu` menu bar app built by script and ad-hoc signed), `posix_spawn` runner, Security.framework
  keychain access, Node-to-Swift parity checklist, CI policy; records the owner's resolved decisions.

### Removed
- The Node CLI (`bin/`, `src/`) and its tests (`test/*.test.mjs` except `check-secrets.test.mjs`, and
  `test/fixtures/`). Parity gate passed first (`docs/design.md` section 14).

### Fixed
- The CLI no longer crashes with an `EPIPE` stack trace when its stdout reader closes early
  (e.g. `sideload doctor | head`).

[Unreleased]: https://github.com/dividedby/sideload/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/dividedby/sideload/releases/tag/v0.2.0
