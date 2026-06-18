import AppKit
import Combine
import Foundation
import UserNotifications

/// Owns the live set of countdown timers and all of their behavior: ticking, completion
/// detection, persistence across relaunch, notifications, and the completion chime.
///
/// UI state is `@MainActor`-isolated and `@Published` so the module's views re-render live.
/// The store drives a single shared ticking task (one timer for the whole module rather than
/// one per countdown) and recomputes derived state from wall-clock `fireDate`s, so the
/// readout stays correct across sleep and clock changes.
@MainActor
final class TimersStore: ObservableObject {
    /// All active, paused, and just-completed timers, newest-relevant first when displayed.
    @Published private(set) var timers: [CountdownTimer] = []

    /// Bumped each tick so views observing remaining time refresh once per second even
    /// though the underlying `fireDate` model objects don't change identity.
    @Published private(set) var tickToken: UInt64 = 0

    /// Set transiently when a timer fires so the compact surface can show a "Time's up"
    /// banner during the peek window; cleared when the peek ends. Carries the fired timer's
    /// display label.
    @Published var completionAlertLabel: String?

    /// Invoked when a timer reaches zero, so the module can peek the notch with the alert.
    /// Carries the timer that fired.
    var onTimerCompleted: ((CountdownTimer) -> Void)?

    private let defaults: UserDefaults
    private let storageKey = "module.timers.timers.v1"

    private var ticker: Task<Void, Never>?
    private var notificationsAuthorized = false

    /// Quick-add presets, in minutes, surfaced in the expanded panel.
    static let presetsMinutes: [Int] = [1, 5, 10, 25]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Lifecycle

    func start() {
        requestNotificationAuthorization()
        // Any timer whose fire date already passed while the app was closed should fire now.
        reconcileMissedFires()
        startTickerIfNeeded()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        persist()
    }

    // MARK: Mutations

    /// Create and start a running timer for `duration` seconds with an optional label.
    @discardableResult
    func addTimer(duration: TimeInterval, label: String = "") -> CountdownTimer {
        let clamped = max(1, duration)
        let timer = CountdownTimer(
            label: label,
            totalDuration: clamped,
            fireDate: Date().addingTimeInterval(clamped),
            state: .running
        )
        timers.append(timer)
        persist()
        scheduleNotification(for: timer)
        startTickerIfNeeded()
        return timer
    }

    func pause(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        guard timers[index].state == .running else { return }
        let remaining = timers[index].remaining()
        timers[index].state = .paused
        timers[index].remainingWhenPaused = remaining
        timers[index].fireDate = nil
        cancelNotification(for: id)
        persist()
        evaluateTicker()
    }

    func resume(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        guard timers[index].state == .paused else { return }
        let remaining = timers[index].remainingWhenPaused ?? 0
        if remaining <= 0 {
            complete(at: index)
            return
        }
        timers[index].fireDate = Date().addingTimeInterval(remaining)
        timers[index].remainingWhenPaused = nil
        timers[index].state = .running
        scheduleNotification(for: timers[index])
        persist()
        startTickerIfNeeded()
    }

    func cancel(_ id: UUID) {
        cancelNotification(for: id)
        timers.removeAll { $0.id == id }
        persist()
        evaluateTicker()
    }

    /// Restart a completed (or any) timer for its original duration.
    func restart(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let duration = timers[index].totalDuration
        timers[index].fireDate = Date().addingTimeInterval(duration)
        timers[index].remainingWhenPaused = nil
        timers[index].state = .running
        scheduleNotification(for: timers[index])
        persist()
        startTickerIfNeeded()
    }

    /// Dismiss a completed timer's lingering entry.
    func dismissCompleted(_ id: UUID) {
        cancel(id)
    }

    // MARK: Derived state

    /// Timers actively counting down.
    var runningTimers: [CountdownTimer] {
        timers.filter { $0.state == .running }
    }

    /// The running timer that will fire soonest — drives the compact ring.
    var soonestRunning: CountdownTimer? {
        runningTimers.min { lhs, rhs in
            (lhs.fireDate ?? .distantFuture) < (rhs.fireDate ?? .distantFuture)
        }
    }

    /// Timers sorted for the expanded list: completed first (need attention), then running by
    /// soonest, then paused, with a stable creation tiebreaker.
    var sortedForDisplay: [CountdownTimer] {
        timers.sorted { lhs, rhs in
            func rank(_ t: CountdownTimer) -> Int {
                switch t.state {
                case .completed: return 0
                case .running: return 1
                case .paused: return 2
                }
            }
            let lr = rank(lhs), rr = rank(rhs)
            if lr != rr { return lr < rr }
            if lhs.state == .running {
                let lf = lhs.fireDate ?? .distantFuture
                let rf = rhs.fireDate ?? .distantFuture
                if lf != rf { return lf < rf }
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Whether the module should contribute compact content: a running timer's ring, or a
    /// transient completion banner during a peek.
    var hasActiveContribution: Bool {
        soonestRunning != nil || completionAlertLabel != nil
    }

    // MARK: Ticking

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        guard !runningTimers.isEmpty else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                if self.runningTimers.isEmpty { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Stop the ticker when nothing is running, or (re)start it when something is.
    private func evaluateTicker() {
        if runningTimers.isEmpty {
            ticker?.cancel()
            ticker = nil
        } else {
            startTickerIfNeeded()
        }
    }

    private func tick() {
        let now = Date()
        var firedIndices: [Int] = []
        for index in timers.indices where timers[index].state == .running {
            if timers[index].hasElapsed(at: now) {
                firedIndices.append(index)
            }
        }
        for index in firedIndices {
            complete(at: index)
        }
        // Drive the once-per-second readout refresh.
        tickToken &+= 1
        if runningTimers.isEmpty {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func complete(at index: Int) {
        guard timers.indices.contains(index) else { return }
        timers[index].state = .completed
        timers[index].fireDate = nil
        timers[index].remainingWhenPaused = nil
        let fired = timers[index]
        persist()
        playChime()
        onTimerCompleted?(fired)
        // The system notification was scheduled at creation; if it hasn't delivered yet
        // (app foreground), surface it now so the user gets the banner.
        deliverImmediateNotificationIfNeeded(for: fired)
    }

    /// On launch, any running timer past its fire date completed while we were closed.
    private func reconcileMissedFires() {
        let now = Date()
        for index in timers.indices where timers[index].state == .running {
            if timers[index].hasElapsed(at: now) {
                timers[index].state = .completed
                timers[index].fireDate = nil
            }
        }
        persist()
    }

    // MARK: Chime

    /// Play the completion chime. Uses a system sound so no asset bundling is required.
    private func playChime() {
        // `NSSound(named:)` resolves built-in system sounds; "Glass" is a pleasant chime.
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: Notifications

    private var notificationCenter: UNUserNotificationCenter {
        UNUserNotificationCenter.current()
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
            }
        }
    }

    /// Schedule a local notification to fire at the timer's fire date. This covers the case
    /// where the app is backgrounded when the timer completes.
    private func scheduleNotification(for timer: CountdownTimer) {
        guard let fireDate = timer.fireDate else { return }
        let interval = fireDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = timer.displayLabel
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: interval,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: notificationIdentifier(for: timer.id),
            content: content,
            trigger: trigger
        )
        notificationCenter.add(request)
    }

    /// Post the completion banner immediately (used when the timer fires while we are running
    /// and the pre-scheduled trigger may not have surfaced a foreground banner).
    private func deliverImmediateNotificationIfNeeded(for timer: CountdownTimer) {
        // Replace any pending scheduled request with an immediate one so the user always
        // gets exactly one banner.
        cancelNotification(for: timer.id)

        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = timer.displayLabel
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notificationIdentifier(for: timer.id),
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func cancelNotification(for id: UUID) {
        let identifier = notificationIdentifier(for: id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func notificationIdentifier(for id: UUID) -> String {
        "module.timers.\(id.uuidString)"
    }

    // MARK: Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(timers)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Persistence is best-effort; a failed encode must not break the running app.
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            timers = try JSONDecoder().decode([CountdownTimer].self, from: data)
        } catch {
            timers = []
        }
    }
}
