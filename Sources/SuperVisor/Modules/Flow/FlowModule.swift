import SwiftUI

/// FlowVisor contributes a break-coaching compact activity and an expanded rhythm card.
@MainActor
final class FlowModule: NotchModule {
    let moduleID = "flow"
    let displayName = "FlowVisor"
    let order = 45

    private let tracker = FlowTracker()

    func activate(_ context: NotchContext) {
        tracker.activate(context)
    }

    func deactivate() {
        tracker.deactivate()
    }

    func compactTrailing() -> AnyView? {
        guard tracker.compactPresentation != nil else { return nil }
        return AnyView(FlowCompactView(tracker: tracker))
    }

    func expandedSection() -> AnyView? {
        guard tracker.hasExpandedPresentation else { return nil }
        return AnyView(FlowExpandedView(tracker: tracker))
    }
}
