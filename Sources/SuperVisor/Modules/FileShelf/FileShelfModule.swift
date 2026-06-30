import SwiftUI

/// ClipVisor — a drag-and-drop file shelf living in the notch.
///
/// The expanded panel exposes a drop zone that stages dropped file URLs in memory with
/// Quick Look thumbnails. Per-file and multi-select actions cover AirDrop, Quick Look
/// preview, Reveal in Finder, Compress to `.zip`, and Remove. Staged files can be dragged
/// back out to any app via their file URL. The compact trailing surface shows a count badge
/// that pulses when a file is dropped.
///
/// All staging state lives in `FileShelfStore` (an `@MainActor ObservableObject`); the views
/// returned here observe it so their subtrees re-render on change without involving the
/// engine. The engine is nudged via `NotchContext` only when the compact contribution
/// appears/disappears (`setNeedsCompactRefresh`) or to peek on a drop (`requestPeek`).
@MainActor
final class FileShelfModule: NotchModule, ObservableObject {
    let moduleID = "fileshelf"
    let displayName = "ClipVisor"
    let order = 40

    private let store = FileShelfStore()
    private var context: NotchContext?

    /// True while a file is being dragged onto the notch, so the shelf surfaces its drop UI
    /// even with nothing staged yet. Set by the engine from the window's drag destination.
    @Published private(set) var dropTargeting = false

    /// Number of currently staged files.
    var stagedCount: Int { store.count }

    /// Toggle the drag-targeting state (engine-driven).
    func setDropTargeting(_ active: Bool) { dropTargeting = active }

    /// Stage dropped file URLs (engine-driven, from a drop onto the notch).
    func stage(urls: [URL]) { store.add(urls: urls) }

    // MARK: Lifecycle

    func activate(_ context: NotchContext) {
        self.context = context

        // Wire the store's engine-facing callbacks. The store never imports the engine; it
        // drives layout/peek purely through these closures.
        store.onCompactPresenceChanged = { [weak context] in
            context?.setNeedsCompactRefresh()
        }
        store.onDropPeek = { [weak context] in
            // Briefly surface the compact badge so a drop is visible without expanding.
            context?.requestPeek(1.6)
        }
    }

    func deactivate() {
        store.clearAll()
        store.onCompactPresenceChanged = nil
        store.onDropPeek = nil
        context = nil
    }

    // MARK: Compact contributions

    func compactTrailing() -> AnyView? {
        guard store.count > 0 else { return nil }
        return AnyView(FileShelfCompactView(store: store))
    }

    // MARK: Expanded section

    /// Only contribute the shelf when a drag is active or files are staged — otherwise the
    /// sheet doesn't show the clip UI at all.
    func expandedSection() -> AnyView? {
        guard dropTargeting || store.count > 0 else { return nil }
        return AnyView(FileShelfExpandedView(store: store, dropTargeting: dropTargeting))
    }
}
