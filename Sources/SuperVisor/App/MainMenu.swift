import AppKit

/// The app's main menu. An accessory app shows no menu bar, yet the menu is where AppKit looks
/// up a key equivalent: ⌘V reaches a text field or a web page only as the key equivalent of an
/// item whose action is `paste:`. With no main menu the editing shortcuts do nothing in any of
/// the app's ordinary windows.
///
/// Every item targets the first responder, so the window and view that hold the keyboard decide
/// what the shortcut does. The notch panel never becomes key and is unaffected.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu(title: "Main")
        main.addItem(submenu(titled: "Edit", items: editItems))
        main.addItem(submenu(titled: "Window", items: windowItems))
        return main
    }

    /// One command: its title, the action sent to the first responder, and its key.
    struct Command: Equatable {
        let title: String
        let action: Selector
        let key: String
        var modifiers: NSEvent.ModifierFlags = .command
    }

    /// `nil` stands for a separator.
    static let editItems: [Command?] = [
        Command(title: "Undo", action: Selector(("undo:")), key: "z"),
        Command(title: "Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
        nil,
        Command(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"),
        Command(title: "Copy", action: #selector(NSText.copy(_:)), key: "c"),
        Command(title: "Paste", action: #selector(NSText.paste(_:)), key: "v"),
        Command(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a"),
    ]

    static let windowItems: [Command?] = [
        Command(title: "Close", action: #selector(NSWindow.performClose(_:)), key: "w"),
        Command(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"),
    ]

    private static func submenu(titled title: String, items: [Command?]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for command in items {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: command.key)
            item.keyEquivalentModifierMask = command.modifiers
            menu.addItem(item)
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
