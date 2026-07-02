import Combine
import EventKit
import SwiftUI

/// Reads incomplete reminders that are due today or overdue through EventKit, and completes
/// them. Requests full Reminders access on first use (a TCC grant separate from Calendar).
/// Re-reads on the system `EKEventStoreChanged` notification and on a periodic tick (so the
/// set rolls over at midnight). All state is `@MainActor`; the reminders fetch is asynchronous,
/// so its completion hops back to the main actor to publish.
@MainActor
final class RemindersService: ObservableObject {
    /// Incomplete reminders due today or earlier, soonest-due first.
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var authorization: EKAuthorizationStatus = .notDetermined

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    var isAuthorized: Bool { authorization == .fullAccess }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    // MARK: Lifecycle

    func start() {
        authorization = EKEventStore.authorizationStatus(for: .reminder)
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
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
            store.requestFullAccessToReminders { [weak self] granted, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorization = EKEventStore.authorizationStatus(for: .reminder)
                    if granted { self.reload() }
                }
            }
        default:
            break  // denied / restricted: nothing to show
        }
    }

    // MARK: Reads

    /// Fetch incomplete reminders due on or before the end of today (i.e. overdue + due-today).
    func reload() {
        guard isAuthorized else {
            if !reminders.isEmpty { reminders = [] }
            return
        }
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: startOfTomorrow, calendars: nil
        )
        store.fetchReminders(matching: predicate) { [weak self] fetched in
            // Runs on an EventKit queue: build value snapshots here, then publish on the main actor.
            // The predicate's end bound is inclusive, so a date-only reminder due *tomorrow*
            // (resolving to tomorrow 00:00 == startOfTomorrow) slips in; filter it back out so we
            // only ever show overdue + due-today.
            let items = (fetched ?? [])
                .compactMap(Self.makeItem)
                .filter { $0.due < startOfTomorrow }
                .sorted { $0.due < $1.due }
            Task { @MainActor in self?.apply(items) }
        }
    }

    private func apply(_ items: [ReminderItem]) {
        if items != reminders { reminders = items }
    }

    // MARK: Actions

    /// Mark a reminder complete. Removes it optimistically so the row leaves immediately, then
    /// persists to EventKit and re-reads.
    func complete(_ id: String) {
        reminders.removeAll { $0.id == id }   // optimistic
        defer { reload() }                    // always reconcile, even on the early return below
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            NSLog("SuperVisor: failed to complete reminder: \(error.localizedDescription)")
        }
    }

    // MARK: Mapping

    /// `nonisolated`: this runs inside the `fetchReminders` completion on an EventKit background
    /// queue. It only reads the passed reminder and returns a value snapshot, so keep it off the
    /// main actor explicitly (rather than relying on the non-`@Sendable` completion hiding it).
    private nonisolated static func makeItem(_ reminder: EKReminder) -> ReminderItem? {
        guard !reminder.isCompleted else { return nil }
        guard let components = reminder.dueDateComponents,
              let due = Calendar.current.date(from: components) else { return nil }
        let title = reminder.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        // `EKCalendarItem.calendar` is implicitly-unwrapped but documented nullable: it resolves
        // to nil when the owning list/account was deleted between the fetch and this mapping
        // (the exact EKEventStoreChanged race window this runs in), so access it optionally.
        let calendar = reminder.calendar
        let accent: Color = calendar?.cgColor.map(Color.init(cgColor:)) ?? .accentColor
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: title,
            due: due,
            hasTime: components.hour != nil,
            priority: reminder.priority,
            listName: calendar?.title ?? "",
            accent: accent
        )
    }
}
