import AppKit
import SwiftUI

/// One choice in a `PanelMenu`. A disabled item says why in its title and in its help text.
struct PanelMenuItem {
    var title: String
    var enabled = true
    var help: String?
    var destructive = false
    var action: @MainActor () -> Void
}

/// A pull-down menu button whose menu opens right-aligned under the button, so it stays over the panel. SwiftUI's `Menu`
/// always opens from the button's leading edge, which runs past the panel's right edge for the buttons at the end of a
/// row. A menu wider than the room between the panel's left edge and the button's right edge starts at the panel's left
/// edge instead.
struct PanelMenu: NSViewRepresentable {
    enum Label {
        case title(String)
        /// An SF Symbol with no border or arrow, and its accessibility label.
        case symbol(String, accessibility: String)
    }

    var label: Label
    var items: [PanelMenuItem]
    var small = false

    func makeNSView(context: Context) -> PanelMenuButton { PanelMenuButton() }

    func updateNSView(_ button: PanelMenuButton, context: Context) {
        button.configure(label: label, items: items, small: small, enabled: context.environment.isEnabled)
    }
}

final class PanelMenuButton: NSPopUpButton {
    private var choices: [PanelMenuItem] = []

    init() {
        super.init(frame: .zero, pullsDown: true)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(label: PanelMenu.Label, items: [PanelMenuItem], small: Bool, enabled: Bool) {
        choices = items
        isEnabled = enabled
        controlSize = small ? .small : .regular
        font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        // A pull-down shows its first item as the button's face; the choices are built when it opens.
        removeAllItems()
        switch label {
        case .title(let title):
            addItem(withTitle: title)
            isBordered = true
            (cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            setAccessibilityLabel(nil)
        case .symbol(let name, let accessibility):
            addItem(withTitle: "")
            let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)
            lastItem?.image = image
            isBordered = false
            imagePosition = .imageOnly
            (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            setAccessibilityLabel(accessibility)
        }
        invalidateIntrinsicContentSize()
    }

    // The choices are built when the menu opens, so every way of opening it comes here: a click, Space or Return
    // (`performClick`) and VoiceOver's press. The native pull-down would show only the hidden title item.
    override func mouseDown(with event: NSEvent) { openMenu() }

    override func performClick(_ sender: Any?) { openMenu() }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }

    private func openMenu() {
        guard isEnabled, !choices.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = font
        for choice in choices {
            let item = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            // The item keeps its own action: a snapshot update while the menu is open replaces `choices`.
            item.representedObject = Choice(choice.action)
            item.isEnabled = choice.enabled
            item.toolTip = choice.help
            if choice.destructive, choice.enabled {
                item.attributedTitle = NSAttributedString(
                    string: choice.title, attributes: [.foregroundColor: NSColor.systemRed, .font: font as Any])
            }
            menu.addItem(item)
        }
        var x = bounds.maxX - menu.size.width
        if let content = window?.contentView {
            x = max(x, convert(NSPoint(x: content.bounds.minX, y: 0), from: content).x)
        }
        let y = isFlipped ? bounds.maxY + 4 : bounds.minY - 4
        highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: self)
        highlight(false)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        (sender.representedObject as? Choice)?.action()
    }

    private final class Choice: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    }
}
