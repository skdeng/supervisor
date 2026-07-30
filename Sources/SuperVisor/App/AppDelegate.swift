import AppKit
import SwiftUI

/// Owns the app lifecycle: sets the accessory activation policy (menu-bar agent, no Dock
/// icon), installs the notch engine, and hosts the status-bar menu (Settings + Quit) and
/// the Settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private lazy var engine = NotchEngine(settings: settings)

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app writes to pipes and sockets whose peer can vanish at any moment — the codex
        // app-server helper, the headless agent CLI, the perl now-playing adapter, and hook
        // clients on the swarm socket. A write after the peer closes raises SIGPIPE, whose
        // default action kills the process with no crash report; ignoring it process-wide turns
        // every such write into an EPIPE error that each client's failure path already handles.
        signal(SIGPIPE, SIG_IGN)

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        AppLog.notice(
            .engine,
            "launch version \(version) pid \(ProcessInfo.processInfo.processIdentifier)"
        )

        // Menu-bar agent: no Dock icon, never the active app's foreground UI.
        NSApp.setActivationPolicy(.accessory)
        AppManagedFileStorage.sweepOrphans()

        installStatusItem()
        engine.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.notice(.engine, "terminate")
        engine.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The notch window is always present; closing the Settings window must not quit.
        false
    }

    // MARK: Status bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "visionpro",
                accessibilityDescription: "SuperVisor"
            )
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit SuperVisor",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    // MARK: Actions

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let moduleInfos = ModuleRegistry.allModules().map {
            ModuleInfo(id: $0.moduleID, displayName: $0.displayName)
        }
        for info in moduleInfos {
            settings.registerModuleIfNeeded(info.id)
        }
        let sorted = moduleInfos.sorted { $0.displayName < $1.displayName }

        let root = SettingsView(settings: settings, modules: sorted)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "SuperVisor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
