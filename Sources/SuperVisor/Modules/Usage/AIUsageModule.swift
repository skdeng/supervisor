import SwiftUI

/// AI Usage — Claude Code and Codex plan-quota runway as tight ticker rows at the bottom of
/// the sheet.
///
/// Each row shows `5h 62% · 7d 34%`-style utilization of that product's subscription
/// rate-limit windows with the next reset time, colored by headroom. A row exists only while
/// its CLI is actively in use (`QuotaMonitor.showsRow` / `CodexQuotaMonitor.showsRow`); the
/// section exists only while at least one row does. No compact/pill presence by design.
@MainActor
final class AIUsageModule: NotchModule, ObservableObject {
    let moduleID = "aiUsage"
    let displayName = "AI Usage"
    let order = 90

    let claudeMonitor = QuotaMonitor()
    let codexMonitor = CodexQuotaMonitor()
    private var context: NotchContext?

    func activate(_ context: NotchContext) {
        self.context = context
        // A presence flip changes the sheet's section list; the revision bump makes the
        // panel re-query sections (the same signal modules use for compact presence).
        let presenceChanged: () -> Void = { [weak self] in
            self?.context?.setNeedsCompactRefresh()
        }
        claudeMonitor.onPresenceChange = presenceChanged
        codexMonitor.onPresenceChange = presenceChanged
        claudeMonitor.start()
        codexMonitor.start()
    }

    func deactivate() {
        claudeMonitor.stop()
        codexMonitor.stop()
        claudeMonitor.onPresenceChange = nil
        codexMonitor.onPresenceChange = nil
        context = nil
    }

    func expandedSection() -> AnyView? {
        guard claudeMonitor.showsRow || codexMonitor.showsRow else { return nil }
        return AnyView(AIUsageSectionView(
            claudeMonitor: claudeMonitor,
            codexMonitor: codexMonitor
        ))
    }
}
