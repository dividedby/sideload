import Security

/// A specific keychain file to use instead of the user's default and search list. Only tests set one (a
/// throwaway keychain). `SecKeychain` is a thread-safe CF object that Swift does not mark `Sendable`.
struct KeychainTarget: @unchecked Sendable {
    let keychain: SecKeychain

    /// Restricts a `SecItemCopyMatching` query to this keychain. With no target the query is left alone.
    static func scope(_ query: inout [String: Any], to target: KeychainTarget?) {
        if let target { query[kSecMatchSearchList as String] = [target.keychain] }
    }

    /// Makes a `SecItemAdd` land in this keychain. With no target the item goes to the default keychain.
    static func place(_ attributes: inout [String: Any], in target: KeychainTarget?) {
        if let target { attributes[kSecUseKeychain as String] = target.keychain }
    }

    /// Offers this keychain to `SecPKCS12Import` (which ignores it in memory-only mode: the spike's proof).
    static func offer(_ options: inout [String: Any], to target: KeychainTarget?) {
        if let target { options[kSecImportExportKeychain as String] = target.keychain }
    }
}
