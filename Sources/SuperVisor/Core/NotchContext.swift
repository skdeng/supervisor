import Foundation

/// Services the engine provides to every module. Modules capture this in activate().
@MainActor
public final class NotchContext {
    /// Force the notch to expand (e.g., an incoming notification).
    public let requestExpand: () -> Void
    /// Force the notch to collapse.
    public let requestCollapse: () -> Void
    /// Briefly present a transient compact update for `seconds`, then auto-collapse.
    public let requestPeek: (_ seconds: TimeInterval) -> Void
    /// Notify the engine a module's COMPACT contribution appeared/disappeared so the
    /// pill re-lays-out. (Internal value changes inside an already-shown compact view
    /// update automatically via @ObservedObject and do NOT need this.)
    public let setNeedsCompactRefresh: () -> Void

    public init(
        requestExpand: @escaping () -> Void,
        requestCollapse: @escaping () -> Void,
        requestPeek: @escaping (TimeInterval) -> Void,
        setNeedsCompactRefresh: @escaping () -> Void
    ) {
        self.requestExpand = requestExpand
        self.requestCollapse = requestCollapse
        self.requestPeek = requestPeek
        self.setNeedsCompactRefresh = setNeedsCompactRefresh
    }
}
