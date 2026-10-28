import AppKit
import SideloadCore
import SwiftUI

/// The sideload menu bar app (design section 12): a window-style `MenuBarExtra`, no Dock icon (`LSUIElement`), no timers.
/// Renew, Install, Remove and the lendable setting run only after the inline confirm.
@main
struct SideloadMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: MenuModel

    init() {
        let model = MenuModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
        // The first load happens at launch, before the panel is ever opened.
        model.reload(force: true)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: StatusIcon.image(for: model.panel.icon))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Ends a running action cleanly. The commands' children (`xcodebuild`, `devicectl`) run in their own process groups, so a
/// plain exit would leave them running with the lock gone: quitting cancels the action, waits a moment for it to wind
/// down, then kills whatever is left, as the CLI's interrupt handler does.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: MenuModel?

    /// How long a cancelled action gets to return before its children are killed.
    private static let quitGrace: Duration = .seconds(3)
    /// The same for SIGTERM and SIGHUP, which a service manager follows with SIGKILL soon.
    private static let signalGrace: Duration = .seconds(1)

    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The default dispositions are ignored so the sources see the signals.
        signalSources = [SIGTERM, SIGHUP].map { signo in
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            source.setEventHandler {
                // Cancel the action first (the runner kills its child on cancel), give it a moment, then kill what is
                // left and exit.
                Task { @MainActor in
                    await Self.stopRunningAction(grace: Self.signalGrace)
                    exit(128 + signo)
                }
            }
            source.resume()
            return source
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.actionBusy else { return .terminateNow }
        Task {
            await Self.stopRunningAction(grace: Self.quitGrace)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func stopRunningAction(grace: Duration) async {
        await MenuShutdown.cancelWaitKill(
            grace: grace, cancel: { model?.cancelAction() }, isBusy: { model?.actionBusy ?? false })
    }
}
