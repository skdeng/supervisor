import AppKit
import SwiftUI

/// A borderless, non-activating panel pinned over the physical notch.
///
/// The panel sits above the status bar, shows on all spaces, floats over fullscreen apps,
/// and is excluded from Mission Control and the window cycle. Its background is fully
/// transparent; the SwiftUI content decides where it is opaque (the pill / expanded panel)
/// and where it is click-through (the surrounding empty area). Hit-testing is forwarded to
/// the hosted SwiftUI view so empty regions pass clicks to the apps beneath.
public final class NotchWindow: NSPanel {
    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // The panel never becomes key/main and never activates the app, so menu-bar focus
        // and the frontmost app are untouched by interactions with the notch.
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // Above the menu bar / status items so the island visually owns the notch region.
        level = .init(Int(CGWindowLevelForKey(.statusWindow)) + 1)

        // Visible on every space, floating over fullscreen apps, ignored by Mission Control
        // and the window cycle.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        // Transparent chrome — the SwiftUI content draws all visible surfaces.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // Pinned in place; the user cannot drag it.
        isMovable = false
        isMovableByWindowBackground = false

        // Keep it out of restoration and screenshots/window pickers where possible.
        isRestorable = false
        animationBehavior = .none
    }

    // A borderless panel is non-key by default; keep it that way so it never steals focus.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Install a SwiftUI root view as the window's content. Empty regions of the view are
    /// transparent and forward clicks to the windows beneath.
    public func setRootView<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        // Let SwiftUI's transparent areas pass clicks through to underlying windows.
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        contentView = hosting
    }
}
