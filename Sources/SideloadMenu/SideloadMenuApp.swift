import AppKit
import SideloadCore
import SwiftUI

/// The sideload menu bar app (design section 12): a window-style `MenuBarExtra`, no Dock icon (`LSUIElement`), no timers.
/// v1 is read-only plus safe actions; every mutating action is visible but disabled until `refresh` and `install` exist.
@main
struct SideloadMenuApp: App {
    @State private var model: MenuModel

    init() {
        let model = MenuModel()
        _model = State(initialValue: model)
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
