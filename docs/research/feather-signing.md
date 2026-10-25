# Feather on-device signing: research notes

Accessed 2026-10-19. Feather source read at tag v2.9.0 (latest release). Read-only research; nothing downloaded or run.

## Summary

- Feather signs on-device with Zsign (a fork of zhlynn/zsign packaged for SwiftPM), linked against OpenSSL 3.3.x. It takes one `.p12` (cert plus private key) and one `.mobileprovision` per certificate entry. Multiple entries are supported, with one default.
- Feather needs no special portal entitlements for itself. Its own entitlements file contains only `get-task-allow`. Any ordinary development profile is enough to sign Feather itself.
- Feather has two install paths. The "pairing" path needs a lockdownd pairing file plus a loopback VPN (LocalDevVPN). The "server" path uses a local HTTPS server and `itms-services`, with no pairing file or VPN. The server path is documented as less reliable.
- Latest release is v2.9.0 (2026-07-05). Assets are `Feather.ipa` and `Feather_Catalyst.zip`. No checksum file is published, but the GitHub API exposes a sha256 `digest` per asset.
- The upstream repo has moved: `khcrysalis/Feather` now resolves to `claration/feather`. The spec should pin the canonical URL and verify the owner.

## Findings

### Signing engine and credential formats

- Engine: submodule `Zsign` from `khcrysalis/Zsign-Package` (branch `package`), a fork of `zhlynn/zsign`. It depends on `krzyzanowskim/OpenSSL` `from: "3.3.3001"`. (Sources 3, 4, 5)
- Certificate input: the import UI accepts a `.p12` file and a `.mobileprovision` file, plus a password field ("Leave it blank if theres no password required"). A separate private key or cert file is not part of the Feather flow. (Source 6)
- Password check: Feather rejects a wrong password at import with a "Bad Password" alert. Its implementation (`FR.checkPasswordForCertificate`) was not located. (Source 6)
- zsign's own check, `CheckCertificate`, uses `PKCS12_parse`. It loads the OpenSSL `default` and `legacy` providers first and does not check the return values. (Source 7)
- zsign's signing init (`ZSignAsset::Init`) tries PEM key, then DER key, then PKCS#12 (with the legacy provider loaded). It then confirms the p12 cert matches the key, and otherwise searches the profile's `DeveloperCertificates` for a cert that pairs with the key. It does not check expiry or chain. (Source 8)
- Storage: each import copies both files into `Documents/Feather/Certificates/<UUID>/`. The password goes into the app's database via `Storage.shared.addCertificate`, not the Keychain. Each import gets its own UUID entry, so multiple certs are supported, and one can be flagged default. (Source 9)
- `CertificateReader` finds the `<?xml` marker in the profile and decodes the plist from there. It does not verify the CMS signature. (Source 10)

### Profiles, bundle IDs, extensions, groups

- Feather deletes the app's existing `embedded.mobileprovision` and `_CodeSignature` before signing, because zsign does not replace it. (Source 11)
- If the user sets a custom bundle ID, Feather rewrites the main app's `CFBundleIdentifier`. It also rewrites every nested `.app` and `.appex` by substituting the old ID string for the new one. It also fixes `WKCompanionAppBundleIdentifier`, `WKAppBundleIdentifier` and `NSExtensionFileProviderDocumentGroup`. (Source 11)
- Entitlements: when no entitlements file is supplied, zsign generates the entitlements from the profile's `Entitlements` dictionary. (Source 8) The app's own original entitlements are not merged in the code I read.
- zsign picks a profile per bundle by checking `endsWith(applicationId, bundleId)`. If none matches, it falls back to the first asset. The code I read has no `*` wildcard expansion and no app-group logic. (Sources 8, 12)
- Unverified: how a wildcard profile (`TEAM.*`) behaves on device. The profile's `application-identifier` would be copied into the signed entitlements, and I did not find code that rewrites it. An explicit App ID per bundle avoids this question.
- Unverified: app extensions and app groups. Each `.appex` is signed, but nothing in the code I read adds or rewrites `com.apple.security.application-groups`. Under an explicit profile, extension IDs would each need their own App ID and profile (Apple portal behavior, general knowledge, not confirmed here). Under a wildcard profile, extensions can only be covered if their IDs are rewritten under the prefix, which Feather's substitution does.

### What Feather needs installed with it

- Per `HOW_IT_WORKS.md` the pairing method opens a heartbeat over TCP, which needs a pairing file from "PlumeImpactor" (now Impactor) and a loopback VPN app (LocalDevVPN). It checks that `10.7.0.1` is reachable, uploads the IPA over AFC to `/PublicStaging/`, and installs it. (Sources 1, 13)
- The server method serves the signed IPA from a local HTTPS server (a `*.backloop.dev` cert) and triggers `itms-services://`. On iOS 18 and later this needed extra entitlements (Associated Domains, Custom Network Protocol, MDM Managed Associated Domains, Network Extensions), so a workaround hosts the manifest on an external service ("plistserver"). The doc says the server path "can be used without a computer, but it is less reliable." (Source 1)
- iOS 17.4 and later uses remote pairing in Feather v2.7.0, and the UI hides the heartbeat controls. A pairing file import is still offered. (Sources 2, 14)
- Pairing file contents: device UDID, host ID, TLS certs, escrow keys. It is made over USB by the "Trust" prompt, with no Apple ID involved. Impactor reads it from `/var/db/lockdown/` on macOS. (Source 15)

### Latest release

- v2.9.0, published 2026-07-05, not a prerelease. Assets: `Feather.ipa` (14,241,853 bytes, sha256 `833c57d3...730ea`) and `Feather_Catalyst.zip`. There is no SHA256SUMS file. The digest field comes from the GitHub API. (Sources 16, 17)

## Implications for sideload

1. `export-cert` should produce a `.p12` containing the dev cert and its key, with a non-empty password. It should also embed the leaf cert, not just the key, because zsign accepts either but Feather's import expects a complete p12. Keep the password in the keychain or a file outside the repo, and never pass it in logged argv. `security export -P` puts it on the command line, so use a restricted-permission process and don't echo the args.
2. P12 encryption: macOS `security export` / Keychain Access historically writes legacy RC2-40/3DES pbe with SHA-1 MAC, and OpenSSL 3's default provider cannot read it without `-legacy` (Sources 18, 19; the macOS behavior is from third-party reports, not Apple docs). zsign loads the legacy provider, so it likely works. Whether the prebuilt krzyzanowskim OpenSSL includes the legacy provider is Unverified. Safest design: after export, re-encrypt to PBES2/AES-256-CBC with PBKDF2 (works under OpenSSL 3.x default). Note that a SHA-256 MAC can break Apple Security-framework import (Source 20), but Feather does not use that path. Offer a `--verify` step that round-trips the p12 with the system's openssl/LibreSSL, and gate on a real test on the device when it becomes possible. Re-encryption requires a tool like openssl, which conflicts with "zero deps", so decide whether that is acceptable.
3. Profile and App ID shape: for Feather itself use an explicit App ID, a development profile that includes the device, and a profile whose cert is the exported one. For Feather's re-signing, give it a profile that matches the target bundle IDs. A wildcard profile plus Feather's bundle-ID rewrite is the lowest-friction option for plain apps (Apollo, Stremio). Apps with extensions or app groups need explicit IDs or must have those entitlements stripped (Unverified how Feather handles them).
4. Install path and spec rule conflicts: the pairing method depends on Impactor-generated pairing files and LocalDevVPN. The spec forbids third-party sideloading tools and "SideStore pairing" with this Apple ID. A pairing file made over USB involves no Apple ID, but obtaining it via Impactor would run a third-party tool. Instead, Feather's server (`itms-services`) path avoids both, with a reliability caveat. If the pairing path is needed, record that the owner must explicitly relax the rule, or produce the file without Impactor (not researched).
5. Feather installs apps it re-signs with the owner's cert, so every Feather-managed app expires with the profile (1 year). The re-sign reminder in the spec must cover profile expiry, not only certs.
6. Download verification: compare the API `digest` to our own SHA-256 of `Feather.ipa`. Record both, because GitHub does not publish a separate checksum file.

## Answered by `export-cert` (2026-10-20)

- Does macOS write the legacy encryption? Yes, measured on macOS 27: `SecItemExport` writes `pbeWithSHAAnd3-KeyTripleDES-CBC` (key bag), `pbeWithSHAAnd40BitRC2-CBC` (certificate bag) and a SHA-1 MAC, no PBES2 (design section 6). `export-cert` records the scheme per export (`encryption` in the ledger) and warns `P12_LEGACY_ENCRYPTION`.
- Re-encrypt to PBES2? Not done: it would need `openssl`, which conflicts with zero dependencies. Revisit only if the first on-device import fails.
- How is the password kept off the command line (implication 1)? The export is in process (`SecItemExport` with the passphrase in `SecItemImportExportKeyParameters`), the password is a generic-password item in the login keychain (`io.github.dividedby.sideload` / `p12`), and it reaches the owner only through `export-cert --copy-password`: a concealed, transient pasteboard item cleared after 90 s. `security export -P` is never used.
- Does the kit's p12 hold the leaf certificate and key? The verify step reopens the file with `SecPKCS12Import` (memory only) and requires the identity whose certificate SHA-1 is the planned one.
- Which profile shape for Feather itself (implication 3)? The planner prefers a wildcard `TEAM.*` development profile that lists the device and embeds the certificate, and warns `PROFILE_NOT_WILDCARD` when only explicit profiles qualify. The owner's Mac has one wildcard profile `7AGMPUPP64.*` with the one certificate and the saved iPhone, so that is the profile exported.
- Profile expiry vs re-sign reminder (implication 5): the ledger tracks certificate and profile expiry (`ledger`, warnings at 60 and 14 days) and the kit README states both dates.

## Open questions

- Is the legacy provider present in krzyzanowskim OpenSSL 3.3.x as built into Feather? Now the first thing the first real kit will answer: import the exported `.p12` in Feather and report whether it accepts it with the right password. Or read that repo's build config.
- Does a wildcard profile (`TEAM.*`) work with zsign's `endsWith(applicationId, bundleId)` match? Unverified until the kit is imported and an app is signed (the install itself is blocked by 0xe8008018 while an Apple Developer Support case is open).
- Where is `FR.checkPasswordForCertificate` implemented, and does it share the zsign `CheckCertificate` path?
- Does zsign rewrite `application-identifier` for wildcard profiles in the swift/obj-c layer (`swift/zsign.mm`)? Not read.
- Does Feather v2.9.0 behave the same on iOS 27? Release notes only mention iOS 26 SDK.
- Can a pairing file be produced with Apple tools only (`xcrun devicectl` / Xcode) for Feather's import? Not researched.
- Is the repo move `khcrysalis` to `claration` official? The API redirect says so, but confirm before adding to the allowed-upstream list.

## Sources (accessed 2026-10-19)

1. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/HOW_IT_WORKS.md - install paths, entitlements, pairing and VPN needs
2. https://github.com/khcrysalis/Feather/releases - release notes for v2.4.0 to v2.9.0 (LocalDevVPN, signing-assets, remote pairing)
3. https://github.com/khcrysalis/Feather - README, Zsign as engine, GPL-3.0
4. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/.gitmodules - Zsign-Package and IDeviceKit submodules
5. https://raw.githubusercontent.com/khcrysalis/Zsign-Package/package/Package.swift - OpenSSL dependency 3.3.3001+
6. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Views/Settings/Certificates/CertificatesAddView.swift - p12 and mobileprovision import, password check
7. https://raw.githubusercontent.com/khcrysalis/Zsign-Package/package/src/certcheck.cpp - PKCS12_parse with legacy provider
8. https://raw.githubusercontent.com/khcrysalis/Zsign-Package/package/src/openssl.cpp - p12 load order, key and profile matching, entitlements from profile
9. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Utilities/Handlers/CertificateFileHandler.swift - storage layout, multiple certs
10. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Utilities/CertificateReader/CertificateReader.swift - profile parsing
11. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Utilities/Handlers/SigningHandler.swift - bundle ID and plugin rewrite, embedded profile removal
12. https://raw.githubusercontent.com/khcrysalis/Zsign-Package/package/src/bundle.cpp - appex signing, profile selection by suffix
13. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Utilities/Handlers/ZsignHandler.swift - p12 and profile passed to Zsign
14. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Views/Settings/Installation/Tunnel%20%26%20Pairing/TunnelView.swift - pairing file and LocalDevVPN UI
15. https://mintlify.wiki/claration/Impactor/concepts/pairing-files - pairing file contents and creation (third-party documentation site)
16. https://api.github.com/repos/khcrysalis/Feather/releases/latest - v2.9.0 tag and assets
17. https://api.github.com/repos/khcrysalis/Feather/releases/tags/v2.9.0 - asset digests, no checksum file
18. https://github.com/mumble-voip/mumble/issues/6653 - macOS keychain RC2-40-CBC p12 fails in OpenSSL 3 default provider
19. https://help.heroku.com/88GYDTB2/how-do-i-configure-openssl-to-allow-the-use-of-legacy-cryptographic-algorithms - re-encrypt to AES-256-CBC
20. https://developer.apple.com/forums/thread/779466 - SecPKCS12Import MAC verification failures with OpenSSL 3 p12s
21. https://api.github.com/repos/khcrysalis/Feather - repo now at claration/feather
22. https://raw.githubusercontent.com/khcrysalis/Feather/v2.9.0/Feather/Supporting%20Files/Feather.entitlements - only `get-task-allow`
