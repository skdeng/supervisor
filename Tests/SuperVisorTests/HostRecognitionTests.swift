import Foundation
import Synchronization
import Testing

@testable import SuperVisor

/// A history lookup a test controls: it records what was asked and where it ran, and answers
/// from a table. While gated, a lookup waits until the test opens the gate before it reads the
/// table, so the test decides when it ends and what it answers.
private final class HistoryStub: Sendable {
    private let state = Mutex<State>(State())
    private let gate = DispatchSemaphore(value: 0)

    private struct State {
        var asked: [String] = []
        var ranOnMainThread = false
        var known: Set<String> = []
        var gated = false
        var waiting = 0
    }

    func closeGate() {
        state.withLock { $0.gated = true }
    }

    /// Lets every lookup waiting at the gate, and every later one, through.
    func openGate() {
        let waiting = state.withLock { state in
            state.gated = false
            defer { state.waiting = 0 }
            return state.waiting
        }
        for _ in 0..<waiting { gate.signal() }
    }

    var asked: [String] { state.withLock { $0.asked } }
    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }

    func know(_ hosts: Set<String>) {
        state.withLock { $0.known = hosts }
    }

    func lookup(_ host: String) -> Bool {
        let onMain = Thread.isMainThread
        let waits = state.withLock { state in
            if state.gated { state.waiting += 1 }
            return state.gated
        }
        if waits { gate.wait() }
        return state.withLock {
            $0.asked.append(host)
            $0.ranOnMainThread = $0.ranOnMainThread || onMain
            return $0.known.contains(host)
        }
    }
}

/// A clock a test moves by hand.
private final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_794_762_720)  // 2026-11-15 09:12 in Los Angeles

    var now: Date { lock.withLock { instant } }

    func advance(hours: Double) {
        lock.withLock { instant = instant.addingTimeInterval(hours * 3_600) }
    }
}

@Suite("Host recognition", .serialized)
@MainActor
struct HostRecognitionTests {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func makeRecognition(
        _ stub: HistoryStub,
        clock: HandClock = HandClock()
    ) -> HostRecognition {
        HostRecognition(timeZone: losAngeles, now: { clock.now }, lookup: { stub.lookup($0) })
    }

    /// Waits until `condition` holds, for answers that arrive from a lookup off the main actor.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            #expect(ContinuousClock.now < deadline, "timed out")
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("An unanswered host has no answer, then the answer arrives and the caller is told", .timeLimit(.minutes(1)))
    func answersLater() async throws {
        let stub = HistoryStub()
        stub.know(["example.com"])
        let recognition = makeRecognition(stub)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        #expect(recognition.recognised("example.com") == nil)
        try await waitUntil { answers == 1 }

        #expect(recognition.recognised("example.com") == true)
        #expect(stub.asked == ["example.com"])
    }

    @Test("A host the browsers do not know is remembered as not recognised, without asking again", .timeLimit(.minutes(1)))
    func unknownHostIsRemembered() async throws {
        let stub = HistoryStub()
        let recognition = makeRecognition(stub)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        #expect(recognition.recognised("new.example.org") == nil)
        try await waitUntil { answers == 1 }
        #expect(recognition.recognised("new.example.org") == false)
        #expect(recognition.recognised("new.example.org") == false)

        #expect(stub.asked == ["new.example.org"])
        #expect(answers == 1)
    }

    @Test("Asking again while a lookup runs starts no second one", .timeLimit(.minutes(1)))
    func oneLookupPerHost() async throws {
        let stub = HistoryStub()
        let recognition = makeRecognition(stub)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        for _ in 0..<5 {
            #expect(recognition.recognised("example.com") == nil)
        }
        try await waitUntil { answers >= 1 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(stub.asked == ["example.com"])
        #expect(answers == 1)
    }

    @Test("The lookup runs off the main thread", .timeLimit(.minutes(1)))
    func lookupIsOffTheMainThread() async throws {
        let stub = HistoryStub()
        let recognition = makeRecognition(stub)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        _ = recognition.recognised("example.com")
        try await waitUntil { answers == 1 }

        #expect(!stub.ranOnMainThread)
    }

    @Test("An answer holds for the local day and is asked for again on the next", .timeLimit(.minutes(1)))
    func answersLastOneLocalDay() async throws {
        let stub = HistoryStub()
        let clock = HandClock()
        let recognition = makeRecognition(stub, clock: clock)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        _ = recognition.recognised("example.com")
        try await waitUntil { answers == 1 }

        // 23:12 the same day in Los Angeles.
        clock.advance(hours: 14)
        stub.know(["example.com"])
        #expect(recognition.recognised("example.com") == false)
        #expect(stub.asked == ["example.com"])

        // 09:12 the next day: the browsers are asked again, and the earlier answer stands in
        // until they answer.
        clock.advance(hours: 10)
        #expect(recognition.recognised("example.com") == false)
        await recognition.settled()
        #expect(answers == 2)
        #expect(recognition.recognised("example.com") == true)
        #expect(stub.asked == ["example.com", "example.com"])
    }

    @Test("Across midnight a recognised host stays recognised while it is looked up again, then takes the new answer", .timeLimit(.minutes(1)))
    func earlierAnswerStandsInAcrossMidnight() async throws {
        let stub = HistoryStub()
        stub.know(["example.com"])
        let clock = HandClock()
        let recognition = makeRecognition(stub, clock: clock)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        _ = recognition.recognised("example.com")
        await recognition.settled()
        #expect(recognition.recognised("example.com") == true)

        // 09:12 the next day, with the history cleared since.
        clock.advance(hours: 24)
        stub.know([])
        stub.closeGate()
        #expect(recognition.recognised("example.com") == true)
        #expect(recognition.recognised("example.com") == true)
        #expect(answers == 1)

        stub.openGate()
        await recognition.settled()
        #expect(answers == 2)
        #expect(recognition.recognised("example.com") == false)
        #expect(stub.asked == ["example.com", "example.com"])
    }

    @Test("A host never answered before the new day has no answer until its lookup ends", .timeLimit(.minutes(1)))
    func unansweredHostAcrossMidnight() async throws {
        let stub = HistoryStub()
        let clock = HandClock()
        let recognition = makeRecognition(stub, clock: clock)

        clock.advance(hours: 24)
        #expect(recognition.recognised("new.example.org") == nil)
        await recognition.settled()
        #expect(recognition.recognised("new.example.org") == false)
    }

    @Test("An answer still standing in when the next midnight passes keeps standing in", .timeLimit(.minutes(1)))
    func earlierAnswerFromTheDayBefore() async throws {
        let stub = HistoryStub()
        stub.know(["example.com"])
        let clock = HandClock()
        let recognition = makeRecognition(stub, clock: clock)

        _ = recognition.recognised("example.com")
        await recognition.settled()

        // The next day the lookup is still running at the following midnight, so the answer
        // from two days before still stands in on the third day.
        clock.advance(hours: 24)
        stub.closeGate()
        #expect(recognition.recognised("example.com") == true)
        clock.advance(hours: 24)
        #expect(recognition.recognised("example.com") == true)
        stub.openGate()
        await recognition.settled()
        #expect(recognition.recognised("example.com") == true)
    }

    @Test("Resetting forgets the answers and drops a lookup still running", .timeLimit(.minutes(1)))
    func resetDropsEverything() async throws {
        let stub = HistoryStub()
        stub.know(["example.com"])
        let recognition = makeRecognition(stub)
        var answers = 0
        recognition.onAnswer = { answers += 1 }

        stub.closeGate()
        _ = recognition.recognised("example.com")
        recognition.reset()
        stub.openGate()
        await recognition.settled()

        #expect(answers == 0)
        // The dropped lookup stored nothing, so the host is asked about afresh.
        #expect(recognition.recognised("example.com") == nil)
        try await waitUntil { answers == 1 }
        #expect(recognition.recognised("example.com") == true)
    }
}
