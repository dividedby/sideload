import Darwin
import Foundation

/// The edits `sign` makes to the unpacked app before it is signed (design section 18, step 3). The tree is the one
/// `ExtractedTree.verify` checked, in a private 0700 scratch folder.
enum BundleRewriter {
    /// Sets `CFBundleIdentifier` in an Info.plist and writes it back in the format it was read in (XML or binary).
    /// Messages never carry plist content. Returns the identifier it replaced.
    @discardableResult
    static func setBundleIdentifier(infoPlist path: String, to bundleId: String, maxBytes: Int = 4 << 20) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid() }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= off_t(maxBytes) else {
            close(fd)
            throw invalid()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                close(fd)
                throw ioError("read")
            }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        close(fd)

        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format))
            as? [String: Any], let old = plist["CFBundleIdentifier"] as? String
        else { throw invalid() }
        plist["CFBundleIdentifier"] = bundleId
        // OpenStep can be read but not written; XML is its closest relative.
        let written = format == .openStep ? PropertyListSerialization.PropertyListFormat.xml : format
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: written, options: 0) else {
            throw invalid()
        }
        try AtomicFile.write(out, to: path, mode: st.st_mode & 0o777)
        return old
    }

    private static func invalid() -> SideloadError {
        SideloadError(
            "INFO_PLIST_INVALID", "The app's Info.plist could not be read, or has no CFBundleIdentifier, or could not be rewritten.",
            fix: "Do not use this IPA.")
    }

    /// Removes the app's `_CodeSignature` and its old `embedded.mobileprovision` (whatever they are: a folder, a file or
    /// a link is removed without being followed) and puts the free profile's exact bytes in their place.
    static func installProfile(_ profile: Data, into app: String) throws {
        for name in ["_CodeSignature", "embedded.mobileprovision"] {
            let path = app + "/" + name
            guard ScratchDirectory.removeTree(path) else { throw ioError("remove", EBUSY) }
        }
        try AtomicFile.write(profile, to: app + "/embedded.mobileprovision", mode: 0o644)
    }
}
