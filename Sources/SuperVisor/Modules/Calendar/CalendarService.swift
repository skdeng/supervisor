import Combine
import EventKit
import SwiftUI

/// Reads upcoming calendar events through EventKit and republishes them for the notch UI.
///
/// Requests full calendar access on first use (the grant persists thanks to the app's stable
/// signed bundle identity). Re-reads on the system `EKEventStoreChanged` notification and on a
/// periodic tick so ended events roll off and new ones appear. All state is `@MainActor`.
@MainActor
final class CalendarService: ObservableObject {
    /// Upcoming timed events (all-day excluded), soonest first, capped to a sane count.
    @Published private(set) var events: [CalendarEvent] = []
    /// Current EventKit authorization for events.
    @Published private(set) var authorization: EKAuthorizationStatus = .notDetermined

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    /// How far ahead to fetch events.
    private let lookahead: TimeInterval = 16 * 3600

    var isAuthorized: Bool { authorization == .fullAccess }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    // MARK: Lifecycle

    func start() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so it is safe to assert main-actor isolation.
            MainActor.assumeIsolated { self?.reload() }
        }
        requestAccessIfNeeded()
    }

    func stop() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
    }

    private func requestAccessIfNeeded() {
        switch authorization {
        case .fullAccess:
            reload()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.authorization = EKEventStore.authorizationStatus(for: .event)
                        if granted { self.reload() }
                    }
                }
            }
        default:
            break  // denied / restricted: nothing to show
        }
    }

    // MARK: Reads

    /// Re-read upcoming timed events from the store. Assigns only on an actual change so the
    /// periodic tick doesn't churn the UI.
    func reload() {
        MeetingDismissalStore.shared.prune()
        guard isAuthorized else {
            if !events.isEmpty { events = [] }
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3600),    // include recently-started meetings
            end: now.addingTimeInterval(lookahead),
            calendars: nil
        )
        let mapped = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.makeEvent)
            .filter { !MeetingDismissalStore.shared.isDismissed($0.id) }
            .prefix(12)
        let next = Array(mapped)
        if next != events { events = next }
    }

    /// The soonest event that is ongoing or starts within `window`.
    func relevantEvent(within window: TimeInterval, asOf now: Date = Date()) -> CalendarEvent? {
        events.first { $0.end > now && $0.start <= now.addingTimeInterval(window) }
    }

    /// The ongoing meeting (in progress, with a detected join link) — i.e. you're "in a
    /// meeting" right now. Drives Meeting Mode.
    func activeMeeting(asOf now: Date = Date()) -> CalendarEvent? {
        events.first { $0.isOngoing(asOf: now) && $0.hasJoin }
    }

    // MARK: Mapping

    private static func makeEvent(_ ek: EKEvent) -> CalendarEvent {
        let link = MeetingLink.detect(in: ek)
        let title = ek.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Event"
        // `EKEvent.calendar` is implicitly-unwrapped but resolves to nil when the owning calendar
        // was deleted between the fetch and this mapping (the EKEventStoreChanged race window),
        // so access it optionally rather than trapping.
        let accent: Color = ek.calendar?.cgColor.map(Color.init(cgColor:)) ?? NotchTheme.brandColor
        // Recurring events share an identifier across instances; qualify with the start time.
        let baseID = ek.eventIdentifier ?? ek.calendarItemIdentifier
        let id = MeetingDismissalStore.occurrenceID(baseIdentifier: baseID, start: ek.startDate)
        return CalendarEvent(
            id: id,
            title: title,
            start: ek.startDate,
            end: ek.endDate,
            isAllDay: ek.isAllDay,
            location: ek.location,
            joinURL: link?.url,
            provider: link?.provider,
            accent: accent
        )
    }
}
