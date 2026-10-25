import Security

/// Why a private-key or password-item operation failed (design section 6). Carries no names, passwords or
/// key material. `report` is the `{code, message, fix}` of the `errors[]` contract.
public enum KeychainFailure: Error, Sendable, Equatable {
    /// The owner (or the keychain's ACL) refused: Deny in the dialog, cancel, or no interaction allowed.
    case denied
    /// The dialog was not answered within the `PromptGuard` timeout.
    case promptTimeout
    /// No identity or item matched.
    case notFound
    /// The matched identity does not belong to the paid team (first OU, free OU denied).
    case notPaidTeam
    /// A PKCS#12 file did not open with the password (`P12Verifier`). Not a refusal by the owner.
    case wrongPassword
    /// The password item could not be added (`SecretStore.addPassword`).
    case passwordStoreFailed(OSStatus)
    /// The password item could not be read (`SecretStore.readPassword`).
    case passwordUnreadable(OSStatus)
    /// No implementation was injected: the inert `Services` default.
    case unavailable
    /// Any other `OSStatus`.
    case status(OSStatus)

    public struct Report: Sendable, Equatable {
        public let code: String
        public let message: String
        public let fix: String
    }

    /// The one place a failure becomes a code, a message and a fix.
    public var report: Report {
        switch self {
        case .denied:
            return Report(
                code: "KEYCHAIN_DENIED", message: "The keychain access was not allowed.",
                fix: "Run it again and choose Allow (not Always Allow) in the keychain dialog.")
        case .promptTimeout:
            return Report(
                code: "KEYCHAIN_PROMPT_TIMEOUT", message: "The keychain dialog was not answered in time.",
                fix: "Run it again and answer the keychain dialog within two minutes.")
        case .notFound:
            return Report(
                code: "CERT_NOT_FOUND", message: "No matching identity was found in the keychain.",
                fix: "Check that the Apple Development identity is in the login keychain.")
        case .notPaidTeam:
            return Report(
                code: "IDENTITY_NOT_PAID_TEAM", message: "The identity does not belong to the paid team.",
                fix: "Only the paid team's identity can be exported.")
        case .wrongPassword:
            return Report(
                code: "P12_VERIFY_FAILED", message: "The exported file did not open with the stored password.",
                fix: "Do not use that file; run the export again.")
        case .passwordStoreFailed(let status):
            return Report(
                code: "PASSWORD_STORE_FAILED", message: "The .p12 password could not be saved (OSStatus \(status)).",
                fix: "Check that the login keychain is unlocked; nothing was exported.")
        case .passwordUnreadable(let status):
            return Report(
                code: "PASSWORD_UNREADABLE", message: "The saved .p12 password could not be read (OSStatus \(status)).",
                fix: "Check that the login keychain is unlocked and allow the access.")
        case .unavailable:
            return Report(
                code: "KEYCHAIN_UNAVAILABLE", message: "No keychain implementation is configured.",
                fix: "Inject one (Services.live wires the Security.framework implementation).")
        case .status(let status):
            return Report(
                code: "KEYCHAIN_READ_FAILED", message: "The keychain call failed (OSStatus \(status)).",
                fix: "Check that the login keychain is unlocked.")
        }
    }

    public var sideloadError: SideloadError {
        SideloadError(report.code, report.message, fix: report.fix)
    }

    /// `Deny`, Cancel, a failed authentication and "no interaction" all mean the owner did not allow it.
    public static func from(status: OSStatus) -> KeychainFailure {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
        case errSecItemNotFound: return .notFound
        default: return .status(status)
        }
    }

    /// `SecPKCS12Import`: a failed MAC or authentication is a wrong password, not a refused dialog (the import
    /// is memory-only and shows none). Everything else is mapped as in `from(status:)`.
    public static func fromImport(status: OSStatus) -> KeychainFailure {
        switch status {
        case errSecAuthFailed, errSecPkcs12VerifyFailure: return .wrongPassword
        default: return from(status: status)
        }
    }

    /// Reading the password item: an owner refusal stays `.denied`; any other failure is the item's own code.
    /// (A missing item is not a failure: the store returns nil.)
    static func fromPasswordRead(status: OSStatus) -> KeychainFailure {
        switch from(status: status) {
        case .status, .notFound: return .passwordUnreadable(status)
        case let other: return other
        }
    }

    /// Adding the password item: an owner refusal stays `.denied`; any other failure (a duplicate included) is
    /// the item's own code.
    static func fromPasswordAdd(status: OSStatus) -> KeychainFailure {
        switch from(status: status) {
        case .status, .notFound: return .passwordStoreFailed(status)
        case let other: return other
        }
    }
}
