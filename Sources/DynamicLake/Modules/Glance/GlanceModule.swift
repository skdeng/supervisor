import Combine
import SwiftUI

/// DynaGlance — at-a-glance weather and your next calendar event.
///
/// Compact leading: a countdown chip for an imminent event (e.g. "Standup 12m"), or, when
/// nothing is imminent, the current temperature with a condition glyph. Expanded: a weather
/// card (temp, condition, hi/lo) plus a short list of upcoming events. Location and calendar
/// access are requested at runtime and degrade gracefully to an inline "open Settings" prompt.
@MainActor
final class GlanceModule: NotchModule, ObservableObject {
    let moduleID = "glance"
    let displayName = "Glance"
    let order = 40

    /// Owned services. Their `@Published` changes are re-published through this module so
    /// the views observing the module re-render.
    let weather = WeatherService()
    let calendar = CalendarService()

    /// A monotonically advancing tick that drives live countdown re-rendering once a minute
    /// (and once on the threshold of an event becoming imminent).
    @Published private(set) var clockTick: Int = 0

    private var context: NotchContext?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTimer: Timer?

    /// Tracks whether we are currently contributing compact content, so we only nudge the
    /// engine to re-lay-out on a genuine appear/disappear edge.
    private var wasContributingCompact = false
    /// Tracks the imminent event we've already peeked for, so a single event peeks once.
    private var lastPeekedEventID: String?

    // MARK: Lifecycle

    func activate(_ context: NotchContext) {
        self.context = context

        // Re-publish child service changes so module-observing views update, and evaluate
        // compact-contribution edges + peek triggers on every change.
        weather.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.afterStateChange() }
            }
            .store(in: &cancellables)

        calendar.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.afterStateChange() }
            }
            .store(in: &cancellables)

        weather.start()
        calendar.start()

        // Drive countdowns: tick every 30s so the "Xm" chip stays current and we can detect
        // an event crossing into the imminent window.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        wasContributingCompact = hasCompactContribution
    }

    func deactivate() {
        tickTimer?.invalidate()
        tickTimer = nil
        cancellables.removeAll()
        weather.stop()
        calendar.stop()
        context = nil
    }

    // MARK: State change handling

    /// Republish to module observers, then reconcile compact layout and peek triggers.
    private func afterStateChange() {
        objectWillChange.send()
        reconcileCompactContribution()
        evaluatePeek()
    }

    private func tick() {
        clockTick &+= 1
        reconcileCompactContribution()
        evaluatePeek()
    }

    /// Tell the engine to re-lay-out only when our compact presence flips.
    private func reconcileCompactContribution() {
        let now = hasCompactContribution
        if now != wasContributingCompact {
            wasContributingCompact = now
            context?.setNeedsCompactRefresh()
        }
    }

    /// Briefly peek the compact surface the moment an event becomes imminent, once per event.
    private func evaluatePeek() {
        guard let imminent = calendar.imminentEvent else { return }
        // Only peek for events starting soon (not ones already in progress on launch).
        let delta = imminent.startDate.timeIntervalSince(Date())
        guard delta > 0, delta <= calendar.imminentWindow else { return }
        guard imminent.id != lastPeekedEventID else { return }
        lastPeekedEventID = imminent.id
        context?.requestPeek(4)
    }

    // MARK: Compact contribution model

    /// True when this module currently has something to show in the collapsed pill: an
    /// imminent event chip, or (as a fallback) a current-weather temperature.
    var hasCompactContribution: Bool {
        if calendar.imminentEvent != nil { return true }
        if weather.snapshot != nil { return true }
        return false
    }

    // MARK: NotchModule UI

    func compactLeading() -> AnyView? {
        guard hasCompactContribution else { return nil }
        return AnyView(GlanceCompactView(module: self))
    }

    func expandedSection() -> AnyView? {
        AnyView(GlanceExpandedView(module: self))
    }
}
