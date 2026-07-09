import SwiftUI

/// Claude Usage — Claude Code plan-quota runway as a single ticker row at the bottom of the sheet.
///
/// Shows `5h 62% · 7d 34%`-style utilization of the subscription rate-limit windows with the
/// next reset time, colored by headroom. The row exists only while Claude Code is actively in
/// use (see `QuotaMonitor.showsRow`); otherwise the module contributes nothing and the sheet
/// is unchanged. No compact/pill presence by design.
@MainActor
final class UsageModule: NotchModule, ObservableObject {
    let moduleID = "usage"
    let displayName = "Claude Usage"
    let order = 90

    let monitor = QuotaMonitor()
    private var context: NotchContext?

    func activate(_ context: NotchContext) {
        self.context = context
        // A presence flip changes the sheet's section list; the revision bump makes the
        // panel re-query sections (the same signal modules use for compact presence).
        monitor.onPresenceChange = { [weak self] in
            self?.context?.setNeedsCompactRefresh()
        }
        monitor.start()
    }

    func deactivate() {
        monitor.stop()
        monitor.onPresenceChange = nil
        context = nil
    }

    func expandedSection() -> AnyView? {
        guard monitor.showsRow else { return nil }
        return AnyView(UsageRowView(monitor: monitor))
    }
}
