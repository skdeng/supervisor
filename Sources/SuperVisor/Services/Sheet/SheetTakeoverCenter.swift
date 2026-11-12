import SwiftUI

/// A module-agnostic way for one view to take over the whole expanded sheet: a picker or a list
/// that deserves the sheet's full width and height while it is open, and hands the sheet back
/// when the user chooses or goes back.
///
/// `ExpandedPanelView` renders the current takeover in place of the section stack, under a header
/// carrying its title and a back button. One takeover shows at a time; presenting another
/// replaces it. `NotchEngine` dismisses any takeover when the sheet closes, so it always reopens
/// on its sections.
@MainActor
final class SheetTakeoverCenter: ObservableObject {
    static let shared = SheetTakeoverCenter()

    struct Takeover {
        /// Stable identity of the presenter, e.g. "audio-output".
        let id: String
        /// Shown in the takeover's header.
        let title: String
        let content: AnyView
    }

    @Published private(set) var current: Takeover?

    private init() {}

    func present(id: String, title: String, content: AnyView) {
        current = Takeover(id: id, title: title, content: content)
    }

    /// Hand the sheet back to its sections, whatever is presented.
    func dismiss() {
        guard current != nil else { return }
        current = nil
    }

    /// Dismiss only the takeover `id` presented, leaving another presenter's in place.
    func dismiss(id: String) {
        guard current?.id == id else { return }
        current = nil
    }
}
