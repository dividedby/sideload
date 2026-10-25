import Foundation

/// The `README.txt` inside a Feather kit. Static text plus dates and the 8-hex certificate fingerprint: never the
/// password, a path, an identity name or a device ID.
enum KitReadme {
    static let p12Name = "sideload-dev.p12"
    static let profileName = "sideload-dev.mobileprovision"
    static let readmeName = "README.txt"

    static func text(
        certFp8: String, certNotAfter: Date, profileExpires: Date, legacyEncryption: Bool, wildcard: Bool
    ) -> String {
        var lines = [
            "sideload: Feather kit",
            "",
            "Files",
            "  \(p12Name)            development certificate and private key (password protected)",
            "  \(profileName)  development provisioning profile for your devices",
            "",
            "Certificate \(certFp8) expires \(CertCheck.isoDate(certNotAfter)).",
            "Profile expires \(CertCheck.isoDate(profileExpires)).",
            "Feather-signed apps stop launching when the profile expires, so re-export before then.",
            "",
            "Import into Feather (on the iPhone)",
            "  1. AirDrop this folder to your own iPhone, or copy the two files into the Files app.",
            "     The .p12 is useless without its password.",
            "  2. Open Feather > Settings > Certificates > + .",
            "  3. Choose \(p12Name) and \(profileName).",
            "  4. Paste the password when asked (below). Feather says \"Bad Password\" if it is wrong.",
            "  5. Delete the files from Files and AirDrop history afterwards.",
            "",
            "Where the password comes from",
            "  It is never in this folder. Two ways to get it, on the Mac:",
            "  a. Run the export again with --copy-password (owner only). It reuses the stored password and puts it on",
            "     the clipboard, marked concealed so clipboard managers skip it. Universal Clipboard pastes it on",
            "     the iPhone. Run it only when Feather is open and you are ready to paste: the clipboard is",
            "     cleared after \(ExportCertCommand.clipboardHoldSeconds) seconds (if you have not copied something else since).",
            "  b. Keychain Access > search \"\(SecurityKeychainSecretStore.service)\" > the item with account \"\(SecurityKeychainSecretStore.account)\" >",
            "     double-click > Show password (asks for your Mac login password).",
            "",
        ]
        if legacyEncryption {
            lines += [
                "Legacy encryption",
                "  This .p12 is encrypted with older algorithms (3DES and RC2-40, SHA-1 MAC), which is what macOS",
                "  writes. Whether Feather reads that is unverified. If Feather rejects the file even with the",
                "  correct password, this is the likely cause; report it rather than retrying.",
                "",
            ]
        }
        if !wildcard {
            lines += [
                "Profile scope",
                "  This profile is for specific app IDs, not a wildcard. Feather may refuse to sign other apps with it.",
                "",
            ]
        }
        return lines.joined(separator: "\n")
    }
}
