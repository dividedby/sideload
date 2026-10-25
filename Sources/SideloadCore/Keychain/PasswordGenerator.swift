/// The export file's password: 20 characters of Crockford base32 (no I, L, O, U), shown in groups of four separated by
/// hyphens (`XXXX-XXXX-XXXX-XXXX-XXXX`, 24 characters): 100 bits, easy to read off a screen and type on a phone.
/// The hyphens are part of the password: what is stored and exported is exactly what is pasted.
public enum PasswordGenerator {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let groups = 5
    static let groupLength = 4

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    public static func generate<G: RandomNumberGenerator>(using rng: inout G) -> String {
        var out = ""
        for group in 0..<groups {
            if group > 0 { out.append("-") }
            for _ in 0..<groupLength { out.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }
        }
        return out
    }
}
