import Darwin
import Foundation

/// Limits applied to an untrusted IPA, before extraction (declared sizes) and again after it (real sizes).
public struct InspectLimits: Sendable, Equatable {
    public var maxFileBytes = UInt64(FetchLimits.maxIPABytes)
    public var maxEntries = 20_000
    /// Sum of the declared uncompressed sizes; also the cap on the extracted tree.
    public var maxTotalBytes: UInt64 = 4 << 30
    public var maxEntryBytes: UInt64 = 2 << 30
    public var maxCentralDirectoryBytes = 16 << 20
    public var maxPlistBytes = 4 << 20
    public var maxToolOutputBytes = 1 << 20
    public var maxTreeDepth = 40
    public var maxExtensions = 64
    public var extractTimeout: Duration = .seconds(180)
    public var toolTimeout: Duration = .seconds(30)
    /// How often the extraction is measured while `ditto` runs.
    public var monitorInterval: Duration = .milliseconds(250)

    public init() {}
}

/// The central directory of a ZIP file: names, kinds and declared sizes only. Nothing is inflated and no local
/// header is read; `ditto` does the extraction. This is the pre-check that refuses an unsafe archive before any
/// byte is written. Names are examined as raw bytes (a NUL or a backslash cannot hide), and no name is ever echoed
/// in an error: entries are reported by index.
enum ZipListing {
    struct Entry: Equatable {
        var name: [UInt8]
        var uncompressedSize: UInt64
        var isDirectory: Bool { name.last == 0x2f }
    }

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let cdSignature: UInt32 = 0x0201_4b50
    private static let eocdSize = 22
    private static let cdFixedSize = 46

    /// Reads and checks the listing of the open file. Throws `IPA_NOT_ZIP`, `IPA_UNSUPPORTED_ZIP`,
    /// `IPA_TOO_MANY_ENTRIES`, `IPA_TOO_LARGE` or `IPA_UNSAFE_ENTRY`.
    static func read(fd: Int32, fileSize: UInt64, limits: InspectLimits) throws -> [Entry] {
        guard fileSize >= UInt64(eocdSize) else { throw notZip() }

        // The end-of-central-directory record is within the last 22 + 65535 bytes. Scan backwards for a signature
        // whose comment length reaches exactly the end of the file; anything else is not a ZIP we accept.
        let tailLength = Int(min(fileSize, UInt64(eocdSize + 0xffff)))
        let tailStart = fileSize - UInt64(tailLength)
        let tail = try readExactly(fd: fd, offset: tailStart, count: tailLength)
        var eocdAt: Int?
        var i = tailLength - eocdSize
        while i >= 0 {
            if le32(tail, i) == eocdSignature, i + eocdSize + Int(le16(tail, i + 20)) == tailLength {
                eocdAt = i
                break
            }
            i -= 1
        }
        guard let at = eocdAt else { throw notZip() }

        let diskNumber = le16(tail, at + 4), cdDisk = le16(tail, at + 6)
        let entriesOnDisk = le16(tail, at + 8), entriesTotal = le16(tail, at + 10)
        let cdSize = le32(tail, at + 12), cdOffset = le32(tail, at + 16)
        if diskNumber != 0 || cdDisk != 0 || entriesOnDisk != entriesTotal { throw unsupported("a multi-disk archive") }
        if entriesTotal == 0xffff || cdSize == 0xffff_ffff || cdOffset == 0xffff_ffff { throw unsupported("a ZIP64 archive") }
        if Int(entriesTotal) > limits.maxEntries {
            throw SideloadError(
                "IPA_TOO_MANY_ENTRIES", "The archive lists \(entriesTotal) entries; the limit is \(limits.maxEntries).",
                fix: "Inspect a normal IPA; this one is refused before anything is extracted.")
        }
        let eocdPosition = tailStart + UInt64(at)
        guard UInt64(cdOffset) + UInt64(cdSize) <= eocdPosition, Int(cdSize) <= limits.maxCentralDirectoryBytes else {
            throw notZip()
        }

        let cd = try readExactly(fd: fd, offset: UInt64(cdOffset), count: Int(cdSize))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(entriesTotal))
        var cursor = 0
        var total: UInt64 = 0
        for index in 0..<Int(entriesTotal) {
            guard cursor + cdFixedSize <= cd.count, le32(cd, cursor) == cdSignature else { throw notZip() }
            let madeBy = le16(cd, cursor + 4)
            let flags = le16(cd, cursor + 8)
            let compressed = le32(cd, cursor + 20), uncompressed = le32(cd, cursor + 24)
            let nameLength = Int(le16(cd, cursor + 28)), extraLength = Int(le16(cd, cursor + 30))
            let commentLength = Int(le16(cd, cursor + 32))
            let attributes = le32(cd, cursor + 38)
            let next = cursor + cdFixedSize + nameLength + extraLength + commentLength
            guard next <= cd.count else { throw notZip() }
            if flags & 0x1 != 0 || flags & 0x40 != 0 { throw unsupported("an encrypted entry") }
            if compressed == 0xffff_ffff || uncompressed == 0xffff_ffff { throw unsupported("a ZIP64 entry") }

            let name = Array(cd[(cursor + cdFixedSize)..<(cursor + cdFixedSize + nameLength)])
            if let reason = unsafeReason(name: name, madeBy: madeBy, attributes: attributes) { throw unsafeEntry(index, reason) }
            if UInt64(uncompressed) > limits.maxEntryBytes { throw tooLarge("An entry declares more than the per-entry limit.") }
            total += UInt64(uncompressed)
            if total > limits.maxTotalBytes { throw tooLarge("The archive declares more uncompressed data than the limit.") }
            entries.append(Entry(name: name, uncompressedSize: UInt64(uncompressed)))
            cursor = next
        }
        guard cursor == cd.count else { throw notZip() }
        return entries
    }

    /// Why an entry cannot be extracted safely, or nil. The reason is a fixed phrase, never the name.
    static func unsafeReason(name: [UInt8], madeBy: UInt16, attributes: UInt32) -> String? {
        if name.isEmpty { return "has an empty name" }
        if name.contains(0) { return "has a NUL in its name" }
        if name.contains(0x5c) { return "has a backslash in its name" }
        if name.contains(where: { $0 < 0x20 || $0 == 0x7f }) { return "has a control character in its name" }
        if name.first == 0x2f { return "has an absolute path" }
        if name.split(separator: 0x2f, omittingEmptySubsequences: false).contains([0x2e, 0x2e]) {
            return "has a '..' path component"
        }
        // The Unix mode sits in the high 16 bits of the external attributes. The host byte (`madeBy >> 8`) is not
        // trusted: `ditto` extracts a symlink whatever host an entry claims (0, 1, 3, 19...), so the file-type bits
        // are checked for every entry that has any.
        switch (attributes >> 16) & 0o170000 {
        case 0, 0o100000, 0o040000: return nil
        case 0o120000: return "is a symbolic link"
        default: return "is a device, FIFO, socket or other special file"
        }
    }

    private static func notZip() -> SideloadError {
        SideloadError("IPA_NOT_ZIP", "The file is not a readable ZIP archive.", fix: "Pass an .ipa file.")
    }

    private static func unsupported(_ what: String) -> SideloadError {
        SideloadError("IPA_UNSUPPORTED_ZIP", "The archive uses \(what), which inspect does not read.", fix: "Inspect an unencrypted, single-file IPA of at most 2 GiB.")
    }

    private static func unsafeEntry(_ index: Int, _ reason: String) -> SideloadError {
        SideloadError(
            "IPA_UNSAFE_ENTRY", "Archive entry \(index) \(reason). The IPA was not extracted.",
            fix: "Do not use this IPA; it is not a normal app archive.")
    }

    private static func tooLarge(_ message: String) -> SideloadError {
        SideloadError("IPA_TOO_LARGE", message + " The IPA was not extracted.", fix: "Inspect a normal IPA.")
    }

    private static func readExactly(fd: Int32, offset: UInt64, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ioError("read")
            }
            if n == 0 { throw notZip() }  // the file ended early
            done += n
        }
        return buffer
    }

    private static func le16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}
