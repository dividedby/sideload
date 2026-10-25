# Stremio for Apple TV: download source

Owner-approved source (2026-10-19): <https://github.com/gorlev/stremio-altstore>. Read via the GitHub API and
raw files on 2026-10-19; nothing was downloaded.

## Summary

- The repo is an **unofficial, third-party AltStore-format index** maintained by `gorlev`. Its README disclaims
  any affiliation with Stremio or SmartCode OOD. The README says MIT; the GitHub API reports the license as "Other".
- The **IPAs themselves are Stremio's official builds** on Stremio's own CDN (`dl.strem.io`). The index only
  points at them. There are no GitHub release assets.
- Each index entry publishes `sha256` and `size`, so a download can be checked against a published digest.
- Bundle ID in the index: `com.stremio.pal` (same for iOS and tvOS). Minimum tvOS: 15.0.
- Declared `entitlements: []`. The README notes Apple Login and Handoff don't work in sideloaded builds.
  Extensions (e.g. Top Shelf) are unknown until the IPA is inspected.

## Details

| Field | Value (latest on 2026-10-19) |
|---|---|
| Index JSON | `https://raw.githubusercontent.com/gorlev/stremio-altstore/main/stremio-tvos.json` |
| Source identifier | `community.stremio.tvos` |
| Version / build | 2.0.8 / 23, dated 2026-09-10 |
| Download URL | `https://dl.strem.io/apple/2.0.8b23/tvos/stremio_tvOS.ipa` |
| Size | 74,055,518 bytes |
| Published sha256 | `46cbac96b1f4cf9b767699a5ad88ac856743f91caf030b0c99a584e99ce20f23` |
| History | 8 entries, back to 2.0.1 build 15 |

The repo is not a fork, has about 50 stars, and was last pushed 2026-09-18. `github.com/Stremio/stremio-tvos`
returns 404, so there is no public official source repo under that name.

## Implications for sideload

- `fetch` allowlist: index URL above, plus downloads matching `https://dl.strem.io/apple/<ver>b<build>/tvos/stremio_tvOS.ipa`.
- Resolve the newest version from `versions[0]` of the index for `com.stremio.pal`; reject any `downloadURL`
  outside the allowlist.
- The index's `sha256` comes from a third party: record it as `upstreamDigest`, compute our own SHA-256 after
  download, and fail on mismatch.
- Re-sign under our own bundle ID (e.g. `io.github.dividedby.stremio.tvos`) so it never overwrites the copy
  atvloadly installed.
- Inspect the downloaded IPA's `PlugIns/` before signing; each extension needs its own explicit App ID.

## Sources

- <https://github.com/gorlev/stremio-altstore>: README (disclaimer, sideload caveats)
- <https://api.github.com/repos/gorlev/stremio-altstore>: fork status, stars, last push, license field
- <https://raw.githubusercontent.com/gorlev/stremio-altstore/main/stremio-tvos.json>: entries, URLs, sha256, sizes
- <https://api.github.com/repos/gorlev/stremio-altstore/releases>: empty (no release assets)
