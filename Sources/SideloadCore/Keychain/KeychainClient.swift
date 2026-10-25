import Foundation

/// The non-secret facts about one certificate that sideload reads: subject OU(s) and expiry. The common
/// name (it can contain an email address) is used once, to set `isAppleDevelopment`, and is never kept here (`KeychainCertificate.commonName` holds it for redaction only).
public struct CertInfo: Sendable, Equatable {
    /// Subject `organizationalUnitName` values, in certificate order. Apple certificates carry exactly one: the team.
    public var ous: [String]
    public var notAfter: Date?
    /// Start of the validity period; nil when the certificate does not expose it.
    public var notBefore: Date?
    /// Subject common name starts with "Apple Development".
    public var isAppleDevelopment: Bool

    public init(
        ous: [String] = [], notAfter: Date? = nil, isAppleDevelopment: Bool = true, notBefore: Date? = nil
    ) {
        self.ous = ous
        self.notAfter = notAfter
        self.notBefore = notBefore
        self.isAppleDevelopment = isAppleDevelopment
    }

    /// The first OU. Team matching and other-team labels use only this.
    public var teamOU: String? { ous.first }


    /// A deny-listed OU anywhere in the subject: a safety rule beyond the first-OU match.
    public var carriesDeniedOU: Bool { ous.contains { Team.denied.contains($0) } }

    /// The locked paid team: the first OU is the paid team, and the free team's OU appears
    /// nowhere in the subject (its certificate is never ours).
    public var isPaidTeam: Bool { teamOU == Team.id && !carriesDeniedOU }

    /// The free team (design section 18): the first OU is the free team and the paid OU appears nowhere in the
    /// subject. Disjoint from `isPaidTeam` by construction; a subject carrying both OUs is neither.
    public var isFreeTeam: Bool { teamOU == Team.free && !ous.contains(Team.paid) }
}

/// A free-team signing identity as the free path may name it: the SHA-1 that `codesign -s` takes, its first
/// 8 digits for output, and the expiry. Never a name.
public struct FreeIdentity: Sendable, Equatable {
    /// Upper-case hex SHA-1 of the certificate DER (`KeychainCertificate.reference`). Never print in full.
    public let sha1: String
    public let notAfter: Date

    public init(sha1: String, notAfter: Date) {
        self.sha1 = sha1
        self.notAfter = notAfter
    }

    /// The first 8 digits of `sha1`, lower case: the only form that reaches output, the ledger and config.
    public var fp8: String { LedgerSync.fp8(sha1) }
}

/// The free-team identity set at one moment (every `isFreeTeam` identity the keychain lists, valid or not,
/// by SHA-1). Taken before and after each `xcodebuild`; a non-empty `diff` is `FREE_CERT_CHANGED`.
public struct FreeIdentitySnapshot: Sendable, Equatable {
    public let sha1s: Set<String>

    public init(_ certificates: [KeychainCertificate]) {
        sha1s = Set(certificates.filter { $0.info.isFreeTeam }.map { $0.reference.uppercased() })
    }

    public static func take(_ keychain: some KeychainClient) throws -> FreeIdentitySnapshot {
        FreeIdentitySnapshot(try keychain.developmentIdentities())
    }

    /// What changed from `self` (before) to `after`. All three lists are sorted SHA-1s.
    public struct Diff: Sendable, Equatable {
        public let added: [String]
        public let removed: [String]
        public let unchanged: [String]

        /// An identity appeared or disappeared.
        public var changed: Bool { !added.isEmpty || !removed.isEmpty }
        public var addedFp8: [String] { added.map(LedgerSync.fp8) }
        public var removedFp8: [String] { removed.map(LedgerSync.fp8) }
    }

    public func diff(to after: FreeIdentitySnapshot) -> Diff {
        Diff(
            added: after.sha1s.subtracting(sha1s).sorted(), removed: sha1s.subtracting(after.sha1s).sorted(),
            unchanged: sha1s.intersection(after.sha1s).sorted())
    }
}

/// A signing identity's certificate plus a stable, non-secret join key.
public struct KeychainCertificate: Sendable, Equatable, CustomReflectable {
    /// Upper-case hex SHA-1 of the certificate DER. Internal only: never print it.
    public var reference: String
    public var info: CertInfo
    /// The identity would be listed by `security find-identity -v -p codesigning`: unexpired and trusted for
    /// code signing. Set by the client that produced it; `false` means not validated, and `CertCheck` ignores it.
    public var isValidForCodeSigning: Bool
    /// The subject common name (it can contain a person's name or email). Kept only so the canary evidence
    /// redaction can look for it in free text: never print it, log it, or put it in output. Not part of equality.
    public var commonName: String?

    public init(
        reference: String, info: CertInfo, isValidForCodeSigning: Bool = false, commonName: String? = nil
    ) {
        self.reference = reference
        self.info = info
        self.isValidForCodeSigning = isValidForCodeSigning
        self.commonName = commonName
    }

    /// Dumps (`String(describing:)`, `dump`) show everything but the common name.
    public var customMirror: Mirror {
        Mirror(
            self, children: ["reference": reference, "info": info, "isValidForCodeSigning": isValidForCodeSigning],
            displayStyle: .struct)
    }

    public static func == (a: KeychainCertificate, b: KeychainCertificate) -> Bool {
        a.reference == b.reference && a.info == b.info && a.isValidForCodeSigning == b.isValidForCodeSigning
    }
}

/// A keychain read failed. The message never carries an identity name.
public struct KeychainError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Read-only keychain access (design section 6). The read path never creates, changes, deletes or exports
/// anything and never touches a private key.
public protocol KeychainClient: Sendable {
    /// Signing identities whose certificate is an "Apple Development" certificate, each flagged with whether it
    /// is valid for code signing (`isValidForCodeSigning`). Invalid identities are still returned.
    func developmentIdentities() throws -> [KeychainCertificate]
}
