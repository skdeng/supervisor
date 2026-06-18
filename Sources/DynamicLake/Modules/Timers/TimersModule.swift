import SwiftUI

/// Countdown timers controlled from the notch.
///
/// Timers are created from the expanded panel (quick presets 1/5/10/25 min plus a custom
/// entry). Each timer counts down against a wall-clock fire date so the readout survives
/// sleep and relaunch. On completion the module posts a `UNUserNotification`, plays a chime,
/// and peeks the notch with a "Time's up" alert. The compact trailing surface shows a
/// circular countdown ring for the soonest active timer; the expanded section lists active,
/// paused, and just-completed timers with pause/resume/cancel/restart and an add control.
@MainActor
final class TimersModule: NotchModule, ObservableObject {
    let moduleID = "timers"
    let displayName = "Timers"
    let order = 40

    /// Child store that owns all timer state, ticking, persistence, and notifications.
    @Published private(set) var store = TimersStore()

    private var context: NotchContext?

    /// Clears the transient completion banner after the peek window ends.
    private var alertClearTask: Task<Void, Never>?

    /// How long the "Time's up" peek banner stays up.
    private let peekDuration: TimeInterval = 4

    /// Whether the compact ring is currently being contributed, so we only ask the engine to
    /// re-lay-out the pill on actual appear/disappear transitions.
    private var contributingCompact = false

    /// Observes the store so compact appear/disappear can drive `setNeedsCompactRefresh`.
    private var observation: Task<Void, Never>?

    func activate(_ context: NotchContext) {
        self.context = context

        store.onTimerCompleted = { [weak self] timer in
            self?.handleCompletion(timer)
        }
        store.start()

        // The compact contribution appears/disappears as timers start and finish; watch the
        // store's published changes and notify the engine on transitions.
        observation = Task { [weak self] in
            guard let self else { return }
            for await _ in self.store.objectWillChange.values {
                // objectWillChange fires before the mutation; hop to the next runloop tick so
                // the new derived state is visible, then reconcile.
                await Task.yield()
                self.reconcileCompactContribution()
            }
        }

        reconcileCompactContribution()
    }

    func deactivate() {
        observation?.cancel()
        observation = nil
        alertClearTask?.cancel()
        alertClearTask = nil
        store.stop()
        context = nil
    }

    // MARK: UI contributions

    func compactTrailing() -> AnyView? {
        guard store.hasActiveContribution else { return nil }
        return AnyView(TimerCompactRing(store: store))
    }

    func expandedSection() -> AnyView? {
        AnyView(TimerExpandedSection(store: store))
    }

    // MARK: Behavior

    private func handleCompletion(_ timer: CountdownTimer) {
        // Surface a transient "Time's up" banner in the compact pill, peek the notch to show
        // it, then clear it when the peek window ends. The system banner is delivered via
        // UNUserNotification and the chime is played by the store.
        store.completionAlertLabel = timer.displayLabel
        reconcileCompactContribution()
        context?.requestPeek(peekDuration)

        alertClearTask?.cancel()
        alertClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.peekDuration ?? 4))
            guard let self, !Task.isCancelled else { return }
            self.store.completionAlertLabel = nil
            self.reconcileCompactContribution()
        }
    }

    /// Tell the engine to re-lay-out the pill only when our compact contribution actually
    /// appears or disappears (value changes within an already-shown view update via the
    /// `@ObservedObject` automatically).
    private func reconcileCompactContribution() {
        let nowContributing = store.hasActiveContribution
        if nowContributing != contributingCompact {
            contributingCompact = nowContributing
            context?.setNeedsCompactRefresh()
        }
    }
}
