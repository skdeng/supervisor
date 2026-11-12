import Foundation

/// Decides which now-playing session the notch presents when several apps hold one.
///
/// The notch follows what is playing:
///   - A session that starts playing takes over, so the most recently started one wins when
///     two play at once.
///   - The presented session stays while it plays. Once it stops, a session still playing takes
///     over; with none playing it stays, so pausing never swaps the notch to another app.
///   - A session the user picks is pinned: it stays, playing or not, until it ends or a
///     different session starts playing.
///
/// macOS's own election is only the tie-break for a cold start with nothing playing. It lags
/// behind what is audible — a browser video can play for minutes while a paused music app stays
/// elected — which is why it does not drive the choice.
struct NowPlayingSelection {
    /// The presented session's `sessionID`.
    private(set) var currentID: String?
    /// The session the user picked, while that pick still holds.
    private(set) var pinnedID: String?
    /// Whether each session in the previous update was playing, used to detect one starting.
    private var wasPlaying: [String: Bool] = [:]
    /// When the previous update was folded in.
    private var lastUpdate = Date.distantPast

    /// Pin the session the user picked. Takes effect on the next `update(with:)`.
    mutating func pin(_ sessionID: String) {
        pinnedID = sessionID
    }

    /// Fold in the latest sessions and return the one to present, or `nil` when there are none.
    mutating func update(with sessions: [NowPlaying], now: Date = Date()) -> NowPlaying? {
        let playing = sessions.filter(\.isPlaying)
        // A session started when it was paused in the previous update and plays now. One the
        // previous update did not hold at all started only if its position was sampled since
        // then: a session that was playing all along and merely went missing from one update
        // returns with its old sample, and must not take over or release a pin.
        let started = playing.filter { session in
            if let played = wasPlaying[session.sessionID] { return !played }
            return session.positionSampledAt > lastUpdate
        }
        wasPlaying = Dictionary(
            sessions.map { ($0.sessionID, $0.isPlaying) }, uniquingKeysWith: { first, _ in first })
        lastUpdate = now

        func session(_ id: String?) -> NowPlaying? {
            guard let id else { return nil }
            return sessions.first { $0.sessionID == id }
        }

        if let pinned = pinnedID,
           session(pinned) == nil || started.contains(where: { $0.sessionID != pinned }) {
            pinnedID = nil
        }

        let chosen: NowPlaying?
        if let pinned = session(pinnedID) {
            chosen = pinned
        } else if let newest = Self.mostRecent(started) {
            chosen = newest
        } else if let current = session(currentID) {
            chosen = current.isPlaying ? current : (Self.mostRecent(playing) ?? current)
        } else {
            chosen = Self.mostRecent(playing)
                ?? sessions.first(where: \.isElected)
                ?? Self.mostRecent(sessions)
        }
        currentID = chosen?.sessionID
        return chosen
    }

    /// The session whose position was sampled last. The elected session, then `sessionID`,
    /// settle a tie so the answer never depends on the order sessions arrive in.
    private static func mostRecent(_ sessions: [NowPlaying]) -> NowPlaying? {
        sessions.max { first, second in
            if first.positionSampledAt != second.positionSampledAt {
                return first.positionSampledAt < second.positionSampledAt
            }
            if first.isElected != second.isElected { return second.isElected }
            return first.sessionID > second.sessionID
        }
    }
}
