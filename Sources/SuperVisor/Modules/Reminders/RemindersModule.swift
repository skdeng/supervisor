import Combine
import SwiftUI

/// TaskVisor — surfaces Apple Reminders that are due today or overdue.
///
/// The compact pill shows a checklist badge with the count (red when anything is overdue); the
/// expanded panel lists those tasks with a tap-to-complete checkbox, the list color, a live
/// due/overdue line, and a high-priority marker. Data and completion go through
/// `RemindersService` (EventKit). Tasks with no due date, and anything due later than today, are
/// intentionally excluded so the notch only shows what's actionable now.
@MainActor
final class RemindersModule: NotchModule, ObservableObject {
    let moduleID = "reminders"
    let displayName = "TaskVisor"
    let order = 30

    let service = RemindersService()
    private var context: NotchContext?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?

    private var hadCompact = false
    private var hadExpanded = false

    // MARK: NotchModule lifecycle

    func activate(_ context: NotchContext) {
        self.context = context
        service.start()

        // `@Published` emits during willSet, so hop to the next main-queue turn before reading
        // back the service's state — otherwise syncContributions() would observe the PREVIOUS
        // value and the badge would lag one change behind (never appearing on the first fetch,
        // and lingering as a stale count after the last reminder is completed).
        service.$reminders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncContributions() }
            .store(in: &cancellables)
        service.$authorization
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncContributions() }
            .store(in: &cancellables)

        // Re-read periodically so the due-today set rolls over at midnight even without an
        // external edit (edits themselves arrive via EKEventStoreChanged).
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.service.reload()
            }
        }

        syncContributions()
    }

    func deactivate() {
        tickTask?.cancel()
        tickTask = nil
        cancellables.removeAll()
        service.stop()
        context = nil
    }

    /// Nudge the engine only when our compact / expanded contribution appears or disappears.
    private func syncContributions() {
        let compact = !service.reminders.isEmpty
        let expanded = service.isDenied || !service.reminders.isEmpty
        if compact != hadCompact || expanded != hadExpanded {
            hadCompact = compact
            hadExpanded = expanded
            context?.setNeedsCompactRefresh()
        }
    }

    // MARK: UI contributions

    func compactTrailing() -> AnyView? {
        guard !service.reminders.isEmpty else { return nil }
        return AnyView(RemindersCompactView(service: service))
    }

    func expandedSection() -> AnyView? {
        if service.isDenied {
            return AnyView(RemindersAccessPromptView())
        }
        guard !service.reminders.isEmpty else { return nil }
        return AnyView(RemindersChecklistView(service: service, onComplete: { [weak self] id in
            self?.service.complete(id)
        }))
    }
}
