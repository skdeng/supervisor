import AppKit
import Testing

@testable import SuperVisor

@Suite("Main menu")
@MainActor
struct MainMenuTests {
    private func item(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == action }
    }

    @Test("The editing shortcuts are key equivalents of items sent to the first responder")
    func editingShortcuts() throws {
        let menu = MainMenu.make()
        let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(NSText.paste(_:)), "v", .command),
            (#selector(NSText.copy(_:)), "c", .command),
            (#selector(NSText.cut(_:)), "x", .command),
            (#selector(NSText.selectAll(_:)), "a", .command),
            (Selector(("undo:")), "z", .command),
            (Selector(("redo:")), "z", [.command, .shift]),
            (#selector(NSWindow.performClose(_:)), "w", .command),
        ]

        for (action, key, modifiers) in expected {
            let found = try #require(item(action, in: menu), "\(action)")
            #expect(found.keyEquivalent == key, "\(action)")
            #expect(found.keyEquivalentModifierMask == modifiers, "\(action)")
            #expect(found.target == nil, "\(action)")
        }
    }

    @Test("No two items share a shortcut")
    func shortcutsAreDistinct() {
        let items = MainMenu.make().items.compactMap(\.submenu).flatMap(\.items)
            .filter { !$0.isSeparatorItem }
        let shortcuts = items.map { "\($0.keyEquivalentModifierMask.rawValue)+\($0.keyEquivalent)" }
        #expect(Set(shortcuts).count == shortcuts.count)
    }
}
