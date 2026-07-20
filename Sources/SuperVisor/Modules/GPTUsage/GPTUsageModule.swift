import SwiftUI

/// GPT Usage — Codex plan-quota runway using the same expanded ticker UX as Claude Usage.
///
/// The row has no compact presence and exists only while Codex is actively writing a local
/// session. `CodexQuotaMonitor` obtains the actual quota snapshot through Codex's supported
/// app-server protocol; transcript contents and authentication files are never read here.
@MainActor
final class GPTUsageModule: NotchModule, ObservableObject {
    let moduleID = "gptUsage"
    let displayName = "GPT Usage"
    let order = 91

    let monitor = CodexQuotaMonitor()
    private var context: NotchContext?

    func activate(_ context: NotchContext) {
        self.context = context
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
        return AnyView(GPTUsageRowView(monitor: monitor))
    }
}
