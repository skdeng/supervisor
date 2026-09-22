import Foundation

/// What the media module wants from the system-audio tap for the current playback state.
enum SpectrumTapIntent: Equatable, Sendable {
    /// Capture now: a track is playing and sound is being produced on this Mac.
    case capture
    /// Let a running tap linger briefly, then stop: playback is paused, or the session reports
    /// playing while no process here produces sound.
    case linger
    /// Stop at once: the feature is off or the tap has failed.
    case stop

    /// `localOutputRunning` is `LocalAudioOutputMonitor`'s answer, or `nil` when it has none.
    /// Unknown falls back to trusting `playing`; the tap's own rebuild backoff bounds the cost
    /// of that being wrong.
    static func resolve(
        enabled: Bool,
        unavailable: Bool,
        playing: Bool,
        localOutputRunning: Bool?
    ) -> SpectrumTapIntent {
        if !enabled || unavailable { return .stop }
        if playing && localOutputRunning != false { return .capture }
        return .linger
    }
}

/// The step the media module takes on the tap for an intent, given what the previous
/// reconcile acted on.
enum SpectrumTapAction: Equatable, Sendable {
    case start
    /// Hold `SpectrumTapAction.settle` before starting: the session has been playing without
    /// sound here for a while and sound just appeared. A system alert flips the local-output
    /// signal for well under a second, and a tap start is heavy, so the signal must hold first.
    /// A play press whose audio starts a moment after the "playing" notification never waits,
    /// because the silent stretch before it is shorter than `settleAfterSilentPlaying`.
    case settleThenStart
    case linger
    case stop

    static let settle: Duration = .milliseconds(1500)
    static let settleAfterSilentPlaying: TimeInterval = 3

    /// - `silentPlayingFor`: how long the session has reported playing while the intent stayed
    ///   `.linger`, or `nil` when it has not.
    /// - `settlePending`: a settle from an earlier reconcile is still counting down; it keeps
    ///   counting rather than being cut short by an unrelated reconcile.
    static func resolve(
        intent: SpectrumTapIntent,
        silentPlayingFor: TimeInterval?,
        settlePending: Bool
    ) -> SpectrumTapAction {
        switch intent {
        case .stop: return .stop
        case .linger: return .linger
        case .capture:
            if settlePending || (silentPlayingFor ?? 0) >= settleAfterSilentPlaying {
                return .settleThenStart
            }
            return .start
        }
    }
}
