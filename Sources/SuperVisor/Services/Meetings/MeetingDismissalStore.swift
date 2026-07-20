import Combine
import Foundation

/// In-memory dismissals for individual calendar occurrences. Every entry dies at its meeting's
/// end, and pruning runs on the calendar reload tick, so the set never outlives the day's
/// dismissed meetings and remains memory-bounded.
@MainActor
final class MeetingDismissalStore: ObservableObject {
    static let shared = MeetingDismissalStore()

    struct DismissedMeeting: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    @Published private(set) var dismissed: [DismissedMeeting] = []

    static func occurrenceID(baseIdentifier: String, start: Date) -> String {
        baseIdentifier + "@" + String(Int(start.timeIntervalSinceReferenceDate))
    }

    func dismiss(id: String, title: String, start: Date, end: Date) {
        let now = Date()
        prune(asOf: now)
        guard end > now else { return }

        var next = dismissed.filter { $0.id != id }
        next.append(DismissedMeeting(id: id, title: title, start: start, end: end))
        dismissed = next.sorted { $0.start < $1.start }
    }

    func restore(_ id: String) {
        let next = dismissed.filter { $0.id != id }
        if next != dismissed { dismissed = next }
    }

    func isDismissed(_ id: String) -> Bool {
        dismissed.contains { $0.id == id }
    }

    func prune(asOf now: Date = Date()) {
        let next = dismissed.filter { $0.end > now }
        if next != dismissed { dismissed = next }
    }
}
