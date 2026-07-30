import SwiftUI

/// A self-contained feature that contributes UI and behavior to the notch.
/// Concrete modules are typically `final class X: NotchModule, ObservableObject`,
/// and the AnyViews they return wrap an `@ObservedObject` of themselves so their
/// own state changes re-render those subtrees independently.
@MainActor
public protocol NotchModule: AnyObject {
    /// Stable unique id, e.g. "media".
    var moduleID: String { get }
    /// Human-readable name (settings UI).
    var displayName: String { get }
    /// Sort order in the expanded panel; lower renders earlier.
    var order: Int { get }

    /// Called once when the engine launches. Begin observing system state here.
    func activate(_ context: NotchContext)
    /// Called on shutdown. Tear down observers.
    func deactivate()

    /// Live-activity content for the COLLAPSED pill. nil contributes nothing.
    /// leading = left of the physical notch, trailing = right of it.
    func compactLeading() -> AnyView?
    func compactTrailing() -> AnyView?

    /// Section shown in the EXPANDED panel. nil contributes nothing.
    func expandedSection() -> AnyView?

    /// Banner shown while a peek this module raised is active. nil falls back to the widened
    /// compact pill.
    ///
    /// It presents below the notch on a screen with a physical cutout, and centered in the pill's
    /// own gap — between the compact columns, with the pill growing around it — on a screen
    /// without one. It must therefore be intrinsically sizable on BOTH axes: no `GeometryReader`
    /// at its root, and `Spacer(minLength:)` rather than a bare `Spacer`, or its natural width
    /// measures as zero and the pill has nothing to grow to.
    func peekBanner() -> AnyView?
}

public extension NotchModule {
    var order: Int { 100 }
    func compactLeading() -> AnyView? { nil }
    func compactTrailing() -> AnyView? { nil }
    func expandedSection() -> AnyView? { nil }
    func peekBanner() -> AnyView? { nil }
}
