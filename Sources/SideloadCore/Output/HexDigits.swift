/// True when `text` is exactly `count` ASCII hex digits: lower-case only, or either case.
func isHex(_ text: String, count: Int, lowercaseOnly: Bool) -> Bool {
    text.utf8.count == count
        && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || (!lowercaseOnly && $0 >= 0x41 && $0 <= 0x46) }
}
