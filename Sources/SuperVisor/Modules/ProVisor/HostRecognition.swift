import Foundation

/// Whether the person's own browsers know a host, answered without waiting on the history files.
///
/// `lookup` reads files from disk, so it runs off the main actor. `recognised` answers at once
/// from what is remembered and, for a host with no answer yet, starts the lookup and calls
/// `onAnswer` when it ends so the caller asks again. Answers are kept for one local day. On the
/// next day each host is looked up afresh, and until that lookup ends the earlier day's answer
/// stands in, so a host known yesterday does not drop out of what is shown while it is asked
/// again. A host with no answer from either day answers nil.
@MainActor
final class HostRecognition {
    private let lookup: @Sendable (String) -> Bool
    private let now: () -> Date
    private let timeZone: TimeZone
    private var day: LocalDay?
    private var answers: [String: Bool] = [:]
    /// The answers of the last day that had any, used while today's lookup for a host runs.
    private var earlierAnswers: [String: Bool] = [:]
    private var pending: Set<String> = []
    /// The lookups started and not yet ended, so a test can wait for them (`settled`).
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Bumped by `reset` and at each new day, so a lookup that outlives either stores nothing.
    private var generation = 0

    /// Called after a lookup stored an answer.
    var onAnswer: (() -> Void)?

    init(
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init,
        lookup: @escaping @Sendable (String) -> Bool
    ) {
        self.timeZone = timeZone
        self.now = now
        self.lookup = lookup
    }

    func recognised(_ host: String) -> Bool? {
        let today = LocalDay(now(), timeZone: timeZone)
        if day != today {
            beginDay(today)
        }
        if let answer = answers[host] { return answer }
        startLookup(host)
        return earlierAnswers[host]
    }

    /// Forgets every answer, from today and before, and ignores any lookup still running.
    func reset() {
        generation += 1
        day = nil
        answers = [:]
        earlierAnswers = [:]
        pending = []
    }

    /// Waits until every lookup started so far has ended, and its answer was stored or
    /// dropped.
    func settled() async {
        while let task = running.values.first {
            await task.value
        }
    }

    /// Starts a new local day. Today's answers become the earlier ones, joined by any earlier
    /// answer for a host whose lookup had not ended; lookups still running are ignored.
    private func beginDay(_ today: LocalDay) {
        let unanswered = earlierAnswers.filter { pending.contains($0.key) }
        earlierAnswers = answers.merging(unanswered) { current, _ in current }
        answers = [:]
        pending = []
        generation += 1
        day = today
    }

    private func startLookup(_ host: String) {
        guard pending.insert(host).inserted else { return }
        let (lookup, started, id) = (self.lookup, generation, UUID())
        running[id] = Task { [weak self] in
            let known = await Task.detached(priority: .utility) { lookup(host) }.value
            self?.finishLookup(host, known: known, started: started)
            self?.running[id] = nil
        }
    }

    private func finishLookup(_ host: String, known: Bool, started: Int) {
        guard started == generation else { return }
        pending.remove(host)
        answers[host] = known
        onAnswer?()
    }
}
