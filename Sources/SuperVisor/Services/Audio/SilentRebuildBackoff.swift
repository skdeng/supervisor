import Foundation

/// Paces the system-audio tap's response to a stream that stays silent while audio is expected.
///
/// A full rebuild is the only recovery from a tap that has genuinely stalled, but silence can
/// also be real (see `LocalAudioOutputMonitor`), and nothing inside the tap distinguishes the
/// two. Each consecutive silent rebuild therefore waits twice as long as the last, from
/// `initialInterval` up to `maxInterval`: a stalled tap still recovers on the first rebuild,
/// while a source that never produces sound here costs a handful of rebuilds in the first
/// minutes and then one per `maxInterval`. Hearing audio after a rebuild proves the tap works
/// and resets the sequence.
///
/// Every rebuild destroys and recreates a process tap and an aggregate device, which is heavy
/// inside coreaudiod and broadcasts a device-list change to every audio client on the machine,
/// so the pacing matters beyond this process.
struct SilentRebuildBackoff: Equatable, Sendable {
    /// Silence that must accumulate since the stream last carried audio (or was started)
    /// before a rebuild is considered at all.
    static let silenceThreshold: TimeInterval = 6
    static let initialInterval: TimeInterval = 10
    static let maxInterval: TimeInterval = 300

    private(set) var consecutiveRebuilds = 0
    private(set) var lastRebuildAt: TimeInterval?

    /// Time that must pass after the last rebuild before the next one is allowed.
    var currentInterval: TimeInterval {
        guard consecutiveRebuilds > 0 else { return 0 }
        let doubled = Self.initialInterval * pow(2, Double(consecutiveRebuilds - 1))
        return min(doubled, Self.maxInterval)
    }

    /// Whether a rebuild is due at `now`, given when the stream last carried audio.
    func isRebuildDue(now: TimeInterval, lastAudibleAt: TimeInterval) -> Bool {
        guard now - lastAudibleAt > Self.silenceThreshold else { return false }
        guard let lastRebuildAt else { return true }
        return now - lastRebuildAt >= currentInterval
    }

    mutating func recordRebuild(at now: TimeInterval) {
        consecutiveRebuilds += 1
        lastRebuildAt = now
    }

    /// Audio heard at `time`. Sound arriving after a rebuild means the tap is healthy again, so
    /// the sequence starts over; sound from before the rebuild says nothing about it.
    mutating func noteAudible(at time: TimeInterval) {
        guard let lastRebuildAt, time > lastRebuildAt else { return }
        reset()
    }

    mutating func reset() {
        consecutiveRebuilds = 0
        lastRebuildAt = nil
    }
}
