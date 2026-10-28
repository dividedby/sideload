import Darwin
import Foundation

/// How the menu app ends while an action may be running. The commands' children (`xcodebuild`, `devicectl`) run in their own
/// process groups, so exiting alone would leave them running with the operation lock gone.
public enum MenuShutdown {
    /// How long a cancelled action gets to return before its children are killed, on quit.
    public static let quitGrace: Duration = .seconds(3)
    /// The same for SIGTERM and SIGHUP, which a service manager follows with SIGKILL soon.
    public static let signalGrace: Duration = .seconds(1)

    /// Cancels the action, waits up to `grace` for it to wind down (cancelling kills the child through the runner), then kills
    /// whatever is left and closes the child registry, as the CLI's interrupt handler does.
    ///
    /// - Parameters:
    ///   - cancel: asks the running action to stop (no-op when none runs).
    ///   - isBusy: whether the action has not returned yet.
    ///   - killChildren: the last resort; the default kills every live child group.
    @MainActor
    public static func cancelWaitKill(
        grace: Duration, cancel: () -> Void, isBusy: () -> Bool,
        killChildren: () -> Void = { LiveChildren.shared.killAll(SIGKILL, closing: true) }
    ) async {
        cancel()
        let deadline = ContinuousClock.now + grace
        while isBusy(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        killChildren()
    }
}
