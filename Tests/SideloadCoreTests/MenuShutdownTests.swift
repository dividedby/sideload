import Foundation
import Testing

@testable import SideloadCore
@testable import SideloadMenu

@MainActor
@Suite("menu shutdown")
struct MenuShutdownTests {
    @Test("cancels first, waits for the action to end, then kills the children once")
    func order() async {
        var events: [String] = []
        var busy = 3
        await MenuShutdown.cancelWaitKill(
            grace: .seconds(120), cancel: { events.append("cancel") },
            isBusy: {
                busy -= 1
                return busy > 0
            }, killChildren: { events.append("kill") })
        #expect(events == ["cancel", "kill"])
        #expect(busy == 0)
    }

    @Test("an action that does not wind down is not waited on past the grace; the children are killed anyway")
    func graceExpires() async {
        var events: [String] = []
        await MenuShutdown.cancelWaitKill(
            grace: .milliseconds(100), cancel: { events.append("cancel") }, isBusy: { true },
            killChildren: { events.append("kill") })
        #expect(events == ["cancel", "kill"])
    }

    @Test("the graces: a quit gets longer than a signal, which a service manager follows with SIGKILL")
    func graces() {
        #expect(MenuShutdown.quitGrace == .seconds(3) && MenuShutdown.signalGrace == .seconds(1))
    }

    @Test("with nothing running it kills at once")
    func idle() async {
        var killed = false
        await MenuShutdown.cancelWaitKill(grace: .seconds(5), cancel: {}, isBusy: { false }, killChildren: { killed = true })
        #expect(killed)
    }

    @Test("a success in a result card is plain text; failed and due keep their colours")
    func resultColours() {
        #expect(MenuTone.good.resultColor == MenuTone.plain.color)
        #expect(MenuTone.failed.resultColor == MenuTone.failed.color)
        #expect(MenuTone.due.resultColor == MenuTone.due.color)
        #expect(MenuTone.neutral.resultColor == MenuTone.neutral.color)
    }
}
