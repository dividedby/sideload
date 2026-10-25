import Foundation

extension NSRegularExpression {
    /// A pattern that is a literal in the source: an invalid one is a programmer error. Compile once, in a
    /// `static let`.
    static func compiled(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch { fatalError("invalid pattern: \(error)") }
    }

    func hasMatch(in string: String) -> Bool {
        firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }
}
