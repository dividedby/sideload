import Foundation
import Security

/// Holds the .p12 password as a generic-password item (design section 6). Read and add only: nothing in
/// sideload updates or deletes the item (deleting from the keychain needs the owner).
public protocol SecretStore: Sendable {
    /// The stored password, or nil when there is none. Throws `KeychainFailure` only: `.denied`,
    /// `.passwordUnreadable` or `.unavailable`.
    func readPassword() throws -> String?
    /// Stores a new password; never overwrites. Throws `KeychainFailure` only: `.denied`,
    /// `.passwordStoreFailed` (a duplicate is `.passwordStoreFailed(errSecDuplicateItem)`) or `.unavailable`.
    func addPassword(_ password: String) throws
}

/// The default in `Services`: a test that forgets to inject a store can never reach the real keychain.
public struct UnavailableSecretStore: SecretStore {
    public init() {}

    public func readPassword() throws -> String? { throw KeychainFailure.unavailable }

    public func addPassword(_ password: String) throws { throw KeychainFailure.unavailable }
}

/// `SecretStore` over `SecItemCopyMatching` / `SecItemAdd` (never `security -w`, which puts the password in
/// argv). The only item it ever touches is service `io.github.dividedby.sideload`, account `p12`.
public struct SecurityKeychainSecretStore: SecretStore {
    public static let service = "io.github.dividedby.sideload"
    public static let account = "p12"

    /// Use only this keychain instead of the user's default and search list. Tests use it for a throwaway keychain.
    let target: KeychainTarget?

    public init() {
        self.target = nil
    }

    init(target: KeychainTarget?) {
        self.target = target
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func readPassword() throws -> String? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        KeychainTarget.scope(&query, to: target)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure.fromPasswordRead(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainFailure.passwordUnreadable(errSecDecode)
        }
        return password
    }

    public func addPassword(_ password: String) throws {
        var attributes = identity
        attributes[kSecAttrLabel as String] = "sideload .p12 password"
        attributes[kSecValueData as String] = Data(password.utf8)
        KeychainTarget.place(&attributes, in: target)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainFailure.fromPasswordAdd(status: status) }
    }
}
