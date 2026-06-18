import EventKit
import Foundation

/// Authorization/availability state for calendar access, surfaced to the UI.
enum CalendarAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

/// A lightweight, value-type view of an upcoming calendar event for the UI to render
/// without holding onto `EKEvent` instances.
struct GlanceEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// Hex-less color components captured from the calendar, for a leading dot.
    let calendarColor: CGColor?

    static func == (lhs: GlanceEvent, rhs: GlanceEvent) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.startDate == rhs.startDate
            && lhs.endDate == rhs.endDate
            && lhs.isAllDay == rhs.isAllDay
    }
}

/// Loads upcoming events from EventKit and keeps a small, sorted window of them. Requests
/// access at runtime, refreshes on `EKEventStoreChanged`, and publishes the next imminent
/// event for the compact pill plus a short list for the expanded panel.
@MainActor
final class CalendarService: NSObject, ObservableObject {
    @Published private(set) var authState: CalendarAuthState = .notDetermined
    /// Upcoming events spanning today and tomorrow, sorted by start time.
    @Published private(set) var upcoming: [GlanceEvent] = []

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    /// How far ahead to surface events in the expanded list.
    private let lookaheadHours: TimeInterval = 36 * 3600
    /// Treat an event as "imminent" (eligible for the compact countdown) within this window.
    let imminentWindow: TimeInterval = 60 * 60

    // MARK: Lifecycle

    func start() {
        authState = Self.mapAuthorization(EKEventStore.authorizationStatus(for: .event))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeChanged),
            name: .EKEventStoreChanged,
            object: store
        )

        requestAccessIfNeeded()

        // Periodic refresh so countdowns and the "next event" stay current even without
        // store-change notifications (e.g. an event simply becoming imminent).
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: store)
    }

    /// Request calendar access, then load. Uses the macOS 14+ full-access API when present
    /// and falls back to the older request method on earlier systems.
    func requestAccessIfNeeded() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { [weak self] granted, _ in
                    Task { @MainActor in self?.handleAccessResult(granted: granted) }
                }
            } else {
                store.requestAccess(to: .event) { [weak self] granted, _ in
                    Task { @MainActor in self?.handleAccessResult(granted: granted) }
                }
            }
        case .fullAccess, .authorized:
            authState = .authorized
            reload()
        case .denied, .restricted, .writeOnly:
            authState = .denied
        @unknown default:
            authState = .unavailable
        }
    }

    private func handleAccessResult(granted: Bool) {
        authState = granted ? .authorized : .denied
        if granted { reload() }
    }

    // MARK: Loading

    @objc private func storeChanged() {
        Task { @MainActor in self.reload() }
    }

    /// Query EventKit for events in the lookahead window and publish a sorted, de-duplicated
    /// list. The EventKit query itself is synchronous and cheap; it runs on the main actor.
    func reload() {
        guard authState == .authorized else { return }

        let now = Date()
        let end = now.addingTimeInterval(lookaheadHours)
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        let events = store.events(matching: predicate)

        let mapped: [GlanceEvent] = events.compactMap { event in
            guard let id = event.eventIdentifier else { return nil }
            // Skip events that have already ended and all-day events that are not today.
            if let eventEnd = event.endDate, eventEnd < now { return nil }
            return GlanceEvent(
                id: id + String(event.startDate?.timeIntervalSince1970 ?? 0),
                title: event.title ?? "(No title)",
                startDate: event.startDate ?? now,
                endDate: event.endDate ?? (event.startDate ?? now),
                isAllDay: event.isAllDay,
                calendarColor: event.calendar?.cgColor
            )
        }
        .sorted { $0.startDate < $1.startDate }

        // Cap the published list; the expanded panel shows only a few.
        upcoming = Array(mapped.prefix(8))
    }

    // MARK: Derived

    /// The next non-all-day event that is upcoming (starts in the future or is in progress).
    var nextTimedEvent: GlanceEvent? {
        let now = Date()
        return upcoming.first { !$0.isAllDay && $0.endDate > now }
    }

    /// The next event whose start falls inside the imminent window — drives the compact chip.
    var imminentEvent: GlanceEvent? {
        let now = Date()
        guard let next = nextTimedEvent else { return nil }
        let delta = next.startDate.timeIntervalSince(now)
        // In progress, or starting within the imminent window.
        if next.startDate <= now && next.endDate > now { return next }
        if delta > 0 && delta <= imminentWindow { return next }
        return nil
    }

    // MARK: Authorization mapping

    private static func mapAuthorization(_ status: EKAuthorizationStatus) -> CalendarAuthState {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .authorized
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .unavailable
        }
    }
}
