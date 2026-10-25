import CryptoKit
import Darwin
import Foundation

/// The App Store Connect API key for `portal`: `$SIDELOAD_HOME/asc/key.json` names the key (`keyId`, `issuerId`,
/// `keyFile`, optional `role`) and `keyFile` is the downloaded private key next to it. The owner creates both.
/// Parse errors never echo file content.
public struct ASCCredentials: Sendable {
    public let keyId: String
    public let issuerId: String
    /// The key's role as the owner recorded it (`Developer`, `Admin`, ...); nil when absent or oddly shaped.
    public let role: String?
    /// The PEM text of the private key.
    public let privateKey: ASCSecret

    public init(keyId: String, issuerId: String, role: String?, privateKey: ASCSecret) {
        self.keyId = keyId
        self.issuerId = issuerId
        self.role = role
        self.privateKey = privateKey
    }

    static let maxKeyBytes = 4096
    static let maxJSONBytes = 4096

    private static let keyIdShape = NSRegularExpression.compiled(#"^[A-Z0-9]{10}$"#)
    private static let keyFileShape = NSRegularExpression.compiled(#"^AuthKey_[A-Z0-9]{10}\.p8$"#)
    private static let issuerShape = NSRegularExpression.compiled(
        #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)
    private static let roleShape = NSRegularExpression.compiled(#"^[A-Za-z][A-Za-z_ ]{0,31}$"#)

    private static let fixSetup =
        "Create $SIDELOAD_HOME/asc/ (mode 0700) holding key.json and the AuthKey_<KEYID>.p8 from App Store Connect (see README)."

    private static func invalid(_ message: String) -> SideloadError {
        SideloadError("ASC_KEY_INVALID", message, fix: "Fix $SIDELOAD_HOME/asc/key.json and the key file (see README).")
    }

    private static func permissions(_ what: String, mode: String) -> SideloadError {
        SideloadError(
            "ASC_KEY_PERMISSIONS", "\(what) must have mode \(mode), be owned by you, and not be a symlink.",
            fix: "chmod \(mode) on it, and check its owner.")
    }

    public static func load(_ paths: Paths) throws -> ASCCredentials {
        // The directory itself: lstat, so a symlink is refused rather than followed.
        var st = stat()
        if lstat(paths.asc, &st) != 0 {
            if errno == ENOENT {
                throw SideloadError(
                    "PORTAL_NOT_CONFIGURED", "No App Store Connect API key is configured.", fix: fixSetup)
            }
            throw ioError("stat")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else {
            throw permissions("$SIDELOAD_HOME/asc", mode: "700")
        }

        guard let jsonData = try readSecretFile(paths.asc + "/key.json", limit: maxJSONBytes) else {
            throw SideloadError("PORTAL_NOT_CONFIGURED", "$SIDELOAD_HOME/asc/key.json is missing.", fix: fixSetup)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: jsonData), case .object(let fields) = json
        else { throw invalid("key.json is not a JSON object.") }

        func string(_ key: String) -> String? {
            if case .string(let s)? = fields[key] { return s }
            return nil
        }
        guard let keyId = string("keyId"), keyIdShape.hasMatch(in: keyId) else {
            throw invalid("key.json keyId must be the key's 10 upper-case letters and digits.")
        }
        guard let issuerId = string("issuerId"), issuerShape.hasMatch(in: issuerId) else {
            throw invalid("key.json issuerId must be the issuer UUID.")
        }
        guard let keyFile = string("keyFile"), keyFileShape.hasMatch(in: keyFile) else {
            throw invalid("key.json keyFile must be a bare file name like AuthKey_<KEYID>.p8.")
        }
        let role = string("role").flatMap { roleShape.hasMatch(in: $0) ? $0 : nil }

        guard let keyData = try readSecretFile(paths.asc + "/" + keyFile, limit: maxKeyBytes) else {
            throw SideloadError(
                "PORTAL_NOT_CONFIGURED", "The key file named in key.json is missing.", fix: fixSetup)
        }
        // Fail here, before any token or request, if the file is not a P-256 PKCS#8 key.
        guard let pem = String(data: keyData, encoding: .utf8), (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
        else { throw invalid("The key file is not a P-256 private key in PEM form.") }
        return ASCCredentials(keyId: keyId, issuerId: issuerId, role: role, privateKey: ASCSecret(pem))
    }

    /// Reads a regular file without following a final symlink (and without blocking on a FIFO, which the
    /// regular-file check then rejects). Nil when it does not exist. Refuses loose
    /// modes, other owners, and files over `limit` bytes.
    private static func readSecretFile(_ path: String, limit: Int) throws -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw permissions("An asc/ file", mode: "600")
            default: throw ioError("open")
            }
        }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw ioError("stat") }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else {
            throw permissions("An asc/ file", mode: "600")
        }
        guard st.st_size <= limit else { throw invalid("An asc/ file is larger than \(limit) bytes.") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw ioError("read")
            }
            if n == 0 { return data }
            data.append(buffer, count: n)
            if data.count > limit { throw invalid("An asc/ file is larger than \(limit) bytes.") }
        }
    }
}
