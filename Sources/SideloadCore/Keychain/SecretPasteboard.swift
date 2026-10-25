import Foundation
import Synchronization

/// Puts the .p12 password on the general pasteboard so Universal Clipboard can paste it on the iPhone (design
/// section 8, `export-cert --copy-password`). `SideloadCore` imports no UI framework: the `sideload` CLI supplies the
/// macOS pasteboard backend, and the default in `Services` is inert. No clipboard tool is shelled out to: it cannot mark the item concealed.
public protocol SecretPasteboard: Sendable {
    /// Replaces the pasteboard contents with `secret`, marked `org.nspasteboard.ConcealedType` and
    /// `org.nspasteboard.TransientType` so clipboard managers skip it. Throws `SideloadError` only.
    func copy(_ secret: String) throws
    /// Clears the pasteboard only if it still holds what `copy` put there (its change count is unchanged), so
    /// something the owner copied since is never wiped. Idempotent; returns whether it cleared. Never throws and
    /// never touches the pasteboard when nothing was copied (safe to call from a signal handler path).
    @discardableResult
    func clearIfOurs() -> Bool
}

/// The default in `Services`: a test that forgets a fake can never touch the real pasteboard.
public struct UnavailableSecretPasteboard: SecretPasteboard {
    public init() {}

    public func copy(_ secret: String) throws {
        throw SideloadError(
            "PASTEBOARD_UNAVAILABLE", "No pasteboard is configured.",
            fix: "The sideload CLI wires the macOS pasteboard; read the password in Keychain Access instead.")
    }

    public func clearIfOurs() -> Bool { false }
}

/// The operations the macOS adapter provides. Kept this small so the "still ours" rule lives in Core and is
/// tested with a fake.
public protocol PasteboardBackend: Sendable {
    var changeCount: Int { get }
    /// Replaces the contents with a concealed, transient string item and returns the resulting change count.
    func replaceWithConcealed(_ secret: String) throws -> Int
    func clear()
}

/// What `ConcealedClipboard.clear()` found.
public enum ClearOutcome: Sendable, Equatable {
    /// This call cleared the pasteboard.
    case cleared
    /// An earlier call (the main flow) had already cleared it.
    case alreadyCleared
    /// The owner copied something else since; it was left alone.
    case changedSince
    /// Nothing was ever copied.
    case nothingCopied

    /// True when the password is no longer on the pasteboard because sideload cleared it.
    public var passwordCleared: Bool { self == .cleared || self == .alreadyCleared }
}

/// `SecretPasteboard` over a backend. Remembers the change count its own write produced; `clearIfOurs` clears
/// only if the count is still that one. One lock covers the whole write and the whole check-and-clear, so a second
/// caller (the signal handler racing the main flow) waits for the first clear to finish and only then reports
/// that it was already cleared: when `clear()` returns, the pasteboard no longer holds the password, unless the
/// caller gave up waiting (the handler waits at most 500 ms).
public final class ConcealedClipboard: SecretPasteboard {
    private enum Slot { case empty, ours(Int), cleared, changed }

    private let backend: any PasteboardBackend
    private let slot = Mutex(Slot.empty)

    public init(backend: any PasteboardBackend) {
        self.backend = backend
    }

    public func copy(_ secret: String) throws {
        do {
            try slot.withLock { $0 = .ours(try backend.replaceWithConcealed(secret)) }
        } catch {
            throw SideloadError(
                "PASTEBOARD_FAILED", "The password could not be placed on the pasteboard.",
                fix:
                    "Read it in Keychain Access instead (service \(SecurityKeychainSecretStore.service), account \(SecurityKeychainSecretStore.account)).")
        }
    }

    public func clearIfOurs() -> Bool { clear() == .cleared }

    /// `clearIfOurs` with the reason: lets a second caller say "already cleared" instead of "it never held it".
    public func clear() -> ClearOutcome {
        slot.withLock { slot -> ClearOutcome in
            switch slot {
            case .empty: return .nothingCopied
            case .cleared: return .alreadyCleared
            case .changed: return .changedSince
            case .ours(let mine):
                guard backend.changeCount == mine else {
                    slot = .changed
                    return .changedSince
                }
                backend.clear()
                slot = .cleared
                return .cleared
            }
        }
    }
}
