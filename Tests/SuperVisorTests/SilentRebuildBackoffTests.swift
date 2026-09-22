import Foundation
import Testing

@testable import SuperVisor

@Suite("Silent rebuild backoff")
struct SilentRebuildBackoffTests {
    @Test("No rebuild until the silence threshold has elapsed")
    func silenceThreshold() {
        let backoff = SilentRebuildBackoff()
        #expect(!backoff.isRebuildDue(now: 105, lastAudibleAt: 100))
        #expect(backoff.isRebuildDue(now: 106.5, lastAudibleAt: 100))
    }

    @Test("Consecutive silent rebuilds double their spacing up to the cap")
    func intervalsDouble() {
        var backoff = SilentRebuildBackoff()
        var now = 0.0
        var observed: [TimeInterval] = []
        for _ in 0..<7 {
            backoff.recordRebuild(at: now)
            observed.append(backoff.currentInterval)
            now += backoff.currentInterval
        }
        #expect(observed == [10, 20, 40, 80, 160, 300, 300])
    }

    @Test("A rebuild is refused before its interval and allowed after it")
    func intervalGate() {
        var backoff = SilentRebuildBackoff()
        backoff.recordRebuild(at: 0)
        backoff.recordRebuild(at: 10)
        // Second rebuild done: the next must wait 20 s, silence alone is not enough.
        #expect(!backoff.isRebuildDue(now: 25, lastAudibleAt: 0))
        #expect(backoff.isRebuildDue(now: 30, lastAudibleAt: 0))
    }

    @Test("Audio heard after a rebuild resets the sequence; audio from before it does not")
    func audibleResets() {
        var backoff = SilentRebuildBackoff()
        backoff.recordRebuild(at: 100)
        backoff.recordRebuild(at: 110)
        backoff.noteAudible(at: 90)
        #expect(backoff.consecutiveRebuilds == 2)
        backoff.noteAudible(at: 111)
        #expect(backoff.consecutiveRebuilds == 0)
        #expect(backoff.lastRebuildAt == nil)
        #expect(backoff.currentInterval == 0)
    }

    @Test("Reset returns to the initial spacing")
    func resetRestartsSpacing() {
        var backoff = SilentRebuildBackoff()
        for i in 0..<5 { backoff.recordRebuild(at: Double(i) * 100) }
        backoff.reset()
        backoff.recordRebuild(at: 1000)
        #expect(backoff.currentInterval == 10)
    }
}
