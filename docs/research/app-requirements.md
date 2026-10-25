# App requirements: Apollo Reborn, Stremio iOS, Stremio tvOS

Accessed 2026-10-19. Web research only; nothing downloaded. Claims not verified from a primary source are marked "Unverified".

## Summary

- Apollo Reborn (formerly Apollo-ImprovedCustomApi) is a tweak injected into a stock Apollo IPA. Official releases are on GitHub at `Apollo-Reborn/Apollo-Reborn`. The release API exposes a SHA-256 digest per asset.
- The standard Apollo Reborn IPA has 1 app plus 6 appex bundles (7 App IDs). A `-NOEXTENSIONS` variant has 1. Push needs an explicit App ID with Push Notifications, so a wildcard can't deliver it.
- Stremio does publish an official sideloadable IPA for iOS, iPadOS and tvOS (blog post, 2026-02-02). I could not find a stable direct download URL, a checksum, or any extension, entitlement or bundle-ID data for it.
- VortX / StremioX is a different, third-party app. Its releases are unsigned, ship `SHA256SUMS.txt`, and include a tvOS IPA with a Top Shelf extension. Do not treat it as Stremio.
- Recommendation: explicit App IDs for Apollo Reborn (needed for push, app groups, and extensions), and prefer the NOEXTENSIONS variant at first. Use a wildcard only for apps with no extension or capability needs.

## Apollo Reborn

**Upstream.** The project was renamed from Apollo-ImprovedCustomApi to Apollo-Reborn, and the official repo is [github.com/Apollo-Reborn/Apollo-Reborn](https://github.com/Apollo-Reborn/Apollo-Reborn). [Balackburn/Apollo](https://github.com/Balackburn/Apollo/releases) is an older mirror and AltStore source (secondary, per a search summary). Pre-built IPAs and sources (AltStore Classic, SideStore, Feather) are also at apolloreborn.app. The repo's `DISTRIBUTION.md` says IPAs are attached to GitHub Releases, with tags like `v1.15.11_3.9.0`.

**Releases and checksums.** The GitHub releases API for 2026-10-09 (`v1.15.11_3.9.0`) lists these assets, each with a `sha256:` digest:
- `Apollo-Reborn-3.9.0.ipa`
- `…-NOEXTENSIONS.ipa`
- `…-GLASS.ipa`
- `…-GLASS-NOEXTENSIONS.ipa`
- `…-GLASSICONS.ipa`
- `…-GLASSICONS-NOEXTENSIONS.ipa`
- two `.deb` files and a dSYMs zip

These are GitHub-computed asset digests, not a project-published checksum file. The README and `DISTRIBUTION.md` do not mention checksums. The CLI should record the digest from the API and also compute its own hash after download.

**The base IPA is not published.** The build pipeline takes a user-supplied URL for a stock Apollo IPA and injects the tweak. The Reborn releases are therefore a re-distribution of a patched third-party binary. The IPAs are what the owner would approve as "upstream releases".

**Extensions.** Apollo has 6 appex bundles: ApolloIntentions, Apollofari, AthenaWidgetExtension, NotificationContentExtension, NotificationServiceExtension, OpenInUIExtension. Since v3.2.0, the standard build swaps AthenaWidgetExtension for `ApolloRebornWidgets.appex`. Bundle IDs are not listed in the docs. Unverified: the original app ID is `com.christianselig.Apollo`, and extension IDs are suffixes of it.

**Entitlements.** The main app carries app-group and keychain-access-group entitlements. `application-identifier` and `team-identifier` are omitted by design, so the signer fills them in. Push uses `aps-environment`. The README states that this entitlement is granted only to paid teams and needs an explicit App ID with Push enabled. iCloud and associated domains are not documented (Unverified; inspect `codesign -d --entitlements` on the approved IPA after download).

**What survives re-signing with a paid dev profile.**
- App groups and keychain groups: the signer rewrites the identifiers. The new group IDs must be registered as App Groups on the portal and enabled on each App ID that uses them. Data from the original install is not carried over.
- Extensions: they survive if each gets its own App ID and a profile. Each appex must also be signed with its own entitlements.
- Push: `aps-environment` is allowed on a paid team, but notifications only arrive if a sender uses your team's APNs credentials for your bundle ID. The upstream push backend uses the original app's keys. The README says the supported route is Bark via a self-hosted apollo-backend (Unverified for a paid account in practice).
- iOS 26+ quirk: the share action ("Open in Apollo") fails unless the signer sets the appex main-binary code-signing flag. AltStore and SideStore do this; Sideloadly and Feather do not (per the README). The README points to `scripts/resign-ipa-codesign.sh`. Our own signer, using Xcode/codesign, needs to be checked against this. Unverified on iOS 27.

## Stremio for iOS

- Official: the Stremio blog post of 2026-02-02 announced a "fully featured sideloadable IPA" for iOS, iPadOS and Apple TV, with Apple login and handoff disabled ([blog](https://blog.stremio.com/stremio-fully-featured-sideloadable-ipa-release-for-ios-ipados-apple-tv-tvos/), [AlternativeTo](https://alternativeto.net/news/2026/2/stremio-releases-full-featured-sideloadable-ipa-app-for-ios-ipados-and-apple-tv)).
- Download: the post points at stremio.com/downloads, but when fetched on 2026-10-19 that page listed no IPA. It listed an AltStore PAL source for Europe/Brazil/Japan, a Stremio Web guide, and the App Store link. A blog commenter on 2026-03-07 also reported no IPA links. The current official direct URL is unknown. Open question for the owner.
- No checksum, extension list, entitlements or bundle ID were found. All Unverified. Plan to inspect the IPA after an owner-approved download.
- Expected capabilities (Unverified): no push, no Apple login (Sign in with Apple is disabled upstream). Likely no app groups.

## Stremio for tvOS

- The same official announcement covers Apple TV. The downloads page shows no tvOS link ("Apple TV" appears only in a platform menu).
- Third-party alternative: VortX/StremioX publishes unsigned `VortX-tvOS-…-ci.ipa` (with Top Shelf extension) and a `-lite` variant (no Top Shelf), plus `SHA256SUMS.txt` and a provenance JSON. It requires tvOS 18 or later ([releases](https://github.com/VortXTV/VortX/releases)). Its own account and streaming core replaced the legacy Stremio core, so it is not the official Stremio app.
- A Top Shelf extension is an appex and needs its own App ID. The Lite variant avoids it. A paid-team tvOS profile also needs the Apple TV's UDID registered, which is a separate portal step from the iPhone.

## Wildcard vs explicit App IDs

- A wildcard App ID (`com.example.*`) cannot carry Push Notifications, App Groups, or other capabilities that need explicit IDs. A wildcard profile also can't match an app-group or push entitlement.
- Extensions must have bundle IDs prefixed by the parent app's ID. With a wildcard, every extension would match the same profile, but any extension requesting an app group would fail.
- Recommendation for this project:
  1. Default to explicit App IDs derived from a stable prefix owned by the owner (not the original `com.christianselig.*`).
  2. For Apollo Reborn, start with the NOEXTENSIONS variant (1 explicit App ID, no push). Move to the full variant (7 App IDs, App Group registered) only if the owner wants widgets, share and push.
  3. Use one wildcard (or explicit) ID for Feather itself, since it needs no capabilities (Unverified for Feather's own entitlements; check its IPA).
  4. Stremio: use a single explicit App ID per platform and enable only capabilities the entitlements require.
- Portal limits: paid accounts have no 10-App-ID/7-day cap. Apple documents a registration limit for App IDs but I did not find a current number, so Unverified. The Apollo docs only say paid accounts have "a much higher limit". The owner's account is also currently blocked by the open Apple case, so none of this is testable.

## Open questions

1. Where is the current official Stremio IPA hosted, and does it come with a hash? Check the Stremio downloads page logged in or by region.
2. Actual entitlements and bundle IDs of each IPA (run `codesign -d --entitlements :-` and read `Info.plist` on owner-approved downloads in an isolated directory).
3. Does our codesign-based signer need the appex main-binary flag on iOS 27?
4. Does Stremio's tvOS build include a Top Shelf appex?
5. Does Mac pairing of the Apple TV interfere with atvloadly? See [Pairing coexistence with atvloadly](tvos-install.md#pairing-coexistence-with-atvloadly): probably safe, confidence medium-low, unproven.

## Sources

- https://github.com/Apollo-Reborn/Apollo-Reborn — rename, distribution, variants, push requirement, appex flag, sideloading notes.
- https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/DISTRIBUTION.md — release tags, variants, 6 appex list, entitlements, 7 App IDs.
- https://api.github.com/repos/Apollo-Reborn/Apollo-Reborn/releases?per_page=3 — v3.9.0 assets with sha256 digests.
- https://github.com/Balackburn/Apollo/releases — older mirror.
- https://blog.stremio.com/stremio-fully-featured-sideloadable-ipa-release-for-ios-ipados-apple-tv-tvos/ — official announcement, disabled features.
- https://alternativeto.net/news/2026/2/stremio-releases-full-featured-sideloadable-ipa-app-for-ios-ipados-and-apple-tv — secondary coverage.
- https://www.stremio.com/downloads — no IPA listed on 2026-10-19.
- https://github.com/VortXTV/VortX/releases — third-party app, unsigned IPAs, SHA256SUMS.txt, tvOS Top Shelf.
