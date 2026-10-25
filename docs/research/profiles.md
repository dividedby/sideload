# Provisioning profiles, certificates, limits (research)

Accessed 2026-10-19. Paid individual account (Account Holder). Claims not confirmed against a primary source are marked "Unverified".

## Summary

- Development profile + Apple Development cert is the right fit: it covers every device type the project targets, Developer Mode is already on for the iPhone, and Apple's docs describe it as the "run on your devices" path. Ad Hoc needs the team's single Apple Distribution cert and an Ad Hoc profile; it works but adds nothing for personal use.
- Cert and profile lifetime is 1 year. The 1-year figure for development certs comes only from a retired 2013 Apple guide; for profiles it is Unverified from a current page. Check the real dates with `security cms -D -i` before trusting it.
- Device limit: 100 per product family per membership year. Disabling a device does not free a slot. Slots are freed only through the removal offer at membership renewal.
- Apple-only tooling works: `xcodebuild -allowProvisioningUpdates` (plus `-allowProvisioningDeviceRegistration`) creates and downloads profiles using the Xcode-held account, with no API key. On this Mac, profiles live in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.
- 0xe8008018 on a fresh paid team matches several unresolved Apple forum threads. DTS says the cause is team-level and visible only to the Developer Programs group. No resolution timeline is published.

## Development vs Ad Hoc

| | Development | Ad Hoc |
|---|---|---|
| Certificate | Apple Development (belongs to an individual) | Apple Distribution (belongs to the team; Account Holder/Admin creates; one per team) |
| Devices | Registered devices | Registered devices |
| get-task-allow | true (standard for development profiles; Unverified on a current Apple page) | false (standard for distribution; Unverified on a current Apple page) |
| Developer Mode | Required on iOS/iPadOS/watchOS/visionOS | Unverified (see below) |
| tvOS | No Developer Mode on tvOS; pairing in Device Hub exposes Developer Settings | Same |

Sources for the table: certificate types and ownership [1][2]; profile creation steps [3][4]; Developer Mode [5][6].

- Apple's Developer Mode doc says it applies to locally installed, development-signed software (Xcode runs, Apple Configurator IPA installs). It does not name Ad Hoc [5]. The WWDC22 session exempts TestFlight, Enterprise in-house and App Store, and says nothing about Ad Hoc [6]. A third-party blog (Diawi) says Ad Hoc does need it [7]. Treat Ad Hoc as "assume required" (Unverified).
- tvOS: "In tvOS, there's no Developer Mode. Just pair your Apple TV using Device Hub and Developer Settings appear on the device." [5]
- Expiry. Development certificates are "valid for one year from date of issue. After a certificate expires, any apps that were signed with that certificate will no longer run on a device." [8] That page is a retired 2013 document. Apple's Developer ID page says "The development versions of your software will continue to run until the provisioning profile used to compile it expires or you revoke your signing certificate." [9] Reading the two together: a profile expiry or cert revocation stops the installed app from launching; cert expiry alone is ambiguous between sources. Re-sign and reinstall before either lapses. Apple can revoke certificates "at any time at its sole discretion" [2].
- Revocation effects documented for Apple Distribution (in-house) are "users will no longer be able to run apps signed with this certificate" [1]. That is not documented for Ad Hoc specifically (Unverified).
- Feather: its README says it is "meant for developer certificates" and credits Zsign for on-device signing. It does not say Development vs Distribution, and does not mention .p12 or profile requirements [10]. Feather works with either type in the community, but this is Unverified. A Development profile pairs with a Development .p12, which is what the spec describes.

## Limits

- Devices: "up to 100 of the following devices, per product family, per membership year": Apple TV, Apple Vision Pro, Apple Watch, iPad, iPhone, iPod touch, Mac [11]. Apple's page lists them as separate families; whether each family gets its own 100 is implied by "per product family" but not spelled out. iPhone/iPad/iPod touch grouping is not specified.
- Removal: "You may disable a device on your list during the year, but doing so won't increase your number of available devices." At the start of a new membership year, the Account Holder/Admin/App Manager is offered removal on first sign-in to Certificates, Identifiers & Profiles. Devices are auto-removed 180 days after membership expiration [11]. Implication: a personal setup (a phone, a TV) will never approach 100, but re-registering is not a way to rotate devices.
- Apple Distribution certs: one of each distribution type per team [1][2]. DTS confirms there are limits on Apple Distribution certificates [12].
- Apple Development certs: DTS (July 2025): "when it comes to Apple Development certificates in a paid team, I'm not aware of any limits," from research "a few years back" [12]. The 2013 guide said one active development cert per team member [8]; it is outdated and conflicts with DTS. Development certs belong to the individual, and the portal appends the computer name [2].
- Automatic signing: `xcodebuild` doc says that for automatic signing it will "create and update profiles, app IDs, and certificates" (local `man xcodebuild`). So yes, Xcode-managed signing can create new certs. It also creates Xcode-managed `XC` App IDs [3]. For this project, avoid unneeded cert churn (each cert carries a private key in the keychain, and the .p12 given to Feather must match the one in the profile).

## Tooling (Apple-only)

- `xcodebuild -allowProvisioningUpdates`: "Allow xcodebuild to communicate with the Apple Developer website. For automatically signed targets, xcodebuild will create and update profiles, app IDs, and certificates. For manually signed targets, xcodebuild will download missing or updated provisioning profiles." `-allowProvisioningDeviceRegistration` registers the destination device and requires the former. `-authenticationKeyPath` is the optional App Store Connect key path; it is not needed when Xcode has the signed-in account (local `man xcodebuild`, verified on this machine).
- Flag works only for automatic signing targets for creation; manual targets can only download [community report: 13; consistent with man page].
- Xcode > Settings > Accounts > Manage Certificates / Download Manual Profiles is the GUI equivalent (Unverified on a current Apple page).
- Profile location. Since Xcode 16, Xcode manages profiles in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`. Older Xcode used `~/Library/MobileDevice/Provisioning Profiles` [14]. Verified locally on this Mac (Xcode 27): the UserData directory exists and holds 3 files; the MobileDevice directory does not exist. Double-clicking a `.mobileprovision` installs it via Xcode. Profile files are named by UUID, not display name [14].
- Inspect a profile (read-only):
  `security cms -D -i "<path>.mobileprovision"` prints a plist containing `ExpirationDate`, `ProvisionedDevices` (UDIDs; do not log), `Entitlements` (including `get-task-allow`), `TeamIdentifier`, `DeveloperCertificates`. Pipe through `plutil -extract <key> raw -` to pull single fields. The command is standard macOS tooling; Apple documents it in Technical Note TN2250-era guidance (Unverified link).
- `security find-identity -v -p codesigning` lists usable identities and shows if a cert is valid locally.

## 0xe8008018 notes

- Error text: "The identity used to sign the executable is no longer valid"; the device logs `MIInstallerErrorDomain 13 ApplicationVerificationFailed` and suggest checking cert expiry. The build validates on the Mac; the device rejects it [15][16].
- Apple DTS (Quinn), thread 755762: the OP revoked certs repeatedly on Apple Support's advice with no effect. A different team (a Personal Team) installed fine. DTS: "this seems to be tied to your primary developer account and only DevPrograms has access to those details." [17]
- Thread 780425 (OP's account was mistakenly deactivated and restored; error persisted with Feedback and a Code-Level Support case open for over a month with no reply by May 2025) [18]. DTS closed it as a duplicate of thread 798110.
- Thread 798110: DTS asks for a Code-Level Support request linking the thread, and offers to "review your setup and account details." No cause, fix or timeline [19].
- Thread 843004 (Aug 2026): paid org team fails, free Apple ID on the same Mac/phone works; clean cert/profile/keychain steps do not help; DTS case open; no replies [15].
- Thread 848821 (Oct 2026, Xcode 27.0): account reinstated after suspension; same error; OP hypothesizes stale revocation state or delayed sync between the account system and device-side trust services. No replies, unconfirmed [16].
- One reply in 755762 reports the error vanished after about a year "without any changes on our side" (no root cause) [17].
- Patterns: all cases are team/account-level, none are fixed by client-side steps, and every thread that got Apple input was routed to a support case. This matches the project's situation (an open Apple Developer Support case). The "newly approved membership" cause specifically is Unverified: no thread covers it, and I found no Apple statement on timelines. Reasonable but unproven hypotheses: stale revocation state, a missing device-side trust entry for a new team, or an account flag.
- Practical: do not keep revoking and regenerating certs (repeated attempts did not help in 755762, and revocation adds churn). Keep the support case updated with the Team ID, error text, Xcode build (27A266a) and, if asked, an IPA and `.xcresult`.

## Recommendation

1. Use Apple Development certificate + Development provisioning profile for the iPhone and Apple TV. It fits Apple's documented development install path, the iPhone has Developer Mode, tvOS needs no Developer Mode, and a single cert with its .p12 doubles as Feather's signing identity.
2. Do not create an Apple Distribution cert or Ad Hoc profile now. It is a possible control experiment against 0xe8008018 (a different cert class might not hit the same account-level state), but it consumes the team's one Distribution cert and the failure is documented as team-level, so it will likely fail the same way. Ask the owner before trying it.
3. Create profiles with `xcodebuild -allowProvisioningUpdates` from the signed-in Xcode account, reading results from the UserData folder. Keep one Development cert; avoid automatic-signing cert churn once the account works.
4. Track expiry: parse `ExpirationDate` via `security cms -D -i`, and warn at 60/30/14 days, using the earlier of cert and profile `notAfter`.
5. Keep pressing Apple Developer Support; there is no client-side fix.

## Open questions

- Does the Ad Hoc profile type require Developer Mode on iOS? (Unverified; Apple's docs do not say.)
- Exact current validity periods for Apple Development certs and profiles (confirm from the local files).
- Does an expired development cert (not profile) stop an installed app, as the 2013 guide says, or only the profile? (Sources differ.)
- Whether Xcode 27 changed Apple Development cert limits (DTS: unknown, not small).
- Whether any Feather version requires a particular cert type.
- Does pairing the Apple TV to Xcode interfere with atvloadly's pairing (separate task).

## Sources (accessed 2026-10-19)

1. https://developer.apple.com/support/certificates/ : one distribution cert per type per team; revocation effects; "Apple can revoke at any time".
2. https://developer.apple.com/help/account/certificates/certificates-overview : certificate types, development certs belong to individuals, distribution to team.
3. https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile : Ad Hoc needs a single distribution cert and registered devices; Xcode manages Ad Hoc profiles with automatic signing.
4. https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile : development profile needs development cert(s) and devices.
5. https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device.md : Developer Mode scope; tvOS has none; Device Hub pairing.
6. https://developer.apple.com/videos/play/wwdc2022/110344/ : Developer Mode for development-signed installs; TestFlight/Enterprise/App Store exempt.
7. https://blog.diawi.com/2022/10/25/developer-mode-required-in-ios-ipados-16 : third-party claim that Ad Hoc needs it.
8. https://developer.apple.com/library/archive/documentation/ToolsLanguages/Conceptual/DevPortalGuide/ManagingiOSDevelopmentCertificates/ManagingiOSDevelopmentCertificates.html : retired 2013 guide: 1-year validity, cert expiry stops apps.
9. https://developer.apple.com/support/developer-id-intermediate-certificate/ : dev builds run until profile expires or cert is revoked.
10. https://github.com/khcrysalis/Feather : Feather on-device signing via Zsign; "developer certificates".
11. https://developer.apple.com/help/account/devices/devices-overview : 100 devices per product family per membership year; removal rules.
12. https://developer.apple.com/forums/thread/792610 : DTS: no known limit on Apple Development certs; limits on Distribution certs.
13. https://testdevlab.com/blog/xcode-provisioning-profile-automation-for-ci : community notes on `-allowProvisioningUpdates` with automatic signing.
14. https://developer.apple.com/forums/thread/812538 and https://forum.xojo.com/t/xcode-16-and-provisioning-profiles/81889 : Xcode 16+ profile folder move.
15. https://developer.apple.com/forums/thread/843004 : 0xe8008018, paid team only, unresolved.
16. https://developer.apple.com/forums/thread/848821 : 0xe8008018 after reinstatement, Xcode 27.0, unresolved.
17. https://developer.apple.com/forums/thread/755762 : DTS: tied to primary developer account; try a different team.
18. https://developer.apple.com/forums/thread/780425 : deactivation/restore case; DTS redirect.
19. https://developer.apple.com/forums/thread/798110 : DTS requests code-level support case.
- Local, read-only: `man xcodebuild` and `ls` of the profile directories on this Mac.
