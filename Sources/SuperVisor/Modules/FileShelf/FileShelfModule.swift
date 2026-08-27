import SwiftUI

/// FileShelf stages dropped files, screenshots, and generated results in one local inbox.
@MainActor
final class FileShelfModule: NotchModule, ObservableObject {
    let moduleID = "fileshelf"
    let displayName = "FileShelf"
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
        store.onCompactPresenceChanged = { [weak context] in
            context?.setNeedsCompactRefresh()
        }
        store.onDropPeek = { [weak context] in
            context?.requestPeek(1.6)
        }
        store.onScreenshotPeek = { [weak context] in
            context?.requestPeek(3.2)
        }
        store.operations.onPresenceChanged = { [weak context] in
            context?.setNeedsCompactRefresh()
        }
        store.beginActivation()
    }

    func deactivate() {
        store.endActivation()
        store.onCompactPresenceChanged = nil
        store.onDropPeek = nil
        store.onScreenshotPeek = nil
        store.operations.onPresenceChanged = nil
        context = nil
    }

    // MARK: Compact contributions

    func compactTrailing() -> AnyView? {
        guard store.count > 0 || store.hasActiveOperations || store.arrivalItem != nil else {
            return nil
        }
        return AnyView(FileShelfCompactView(store: store))
    }

    // MARK: Side card

    /// Whether the detached side card has anything to show. It stays available while an
    /// operation is visible so paid work can be inspected and cancelled after its source item
    /// leaves the shelf, and while a drag is in flight so the drop zone can receive it.
    var wantsSideCard: Bool {
        dropTargeting
            || store.count > 0
            || store.arrivalItem != nil
            || !store.operations.operations.isEmpty
    }

    /// The shelf's only expanded surface: a detached card beside the sheet. It contributes no
    /// `expandedSection()`. The engine reads this directly — the shelf is the one module with a
    /// surface outside the sheet, and widening the module protocol for a single implementor
    /// would push a dead requirement onto every other module.
    func sideCard() -> AnyView? {
        guard wantsSideCard else { return nil }
        return AnyView(FileShelfSideCardView(store: store, dropTargeting: dropTargeting))
    }
}
