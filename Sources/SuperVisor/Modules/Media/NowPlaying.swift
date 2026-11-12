import Foundation

/// The app a now-playing session belongs to, as MediaRemote identifies it.
struct NowPlayingApp: Hashable, Sendable {
    let bundleIdentifier: String
    let processID: Int32
}

/// One read of every app's now-playing session, as the entitled helper reported it.
struct NowPlayingCapture: Sendable {
    /// Sessions in a stable order (app name, then process), so a list of them does not
    /// reshuffle between captures.
    let sessions: [NowPlaying]
    /// When the helper took the read. Orders captures that arrive from two helpers at once.
    let capturedAt: Date?

    /// Sessions past this count are ignored; the helper applies the same bound.
    static let maxSessions = 8

    /// Parse one line of the helper's output — `{"capturedAt": …, "sessions": [...]}`. Returns
    /// `nil` when the line carries no session list, which is how the helper reports a read that
    /// could not be completed; that is distinct from an empty list, which means no app has a
    /// session. Unusable entries are dropped, and a second entry for a session already seen is
    /// ignored.
    init?(json: [String: Any]) {
        guard let entries = json["sessions"] as? [Any] else { return nil }
        var seen = Set<String>()
        self.sessions = entries
            .compactMap { ($0 as? [String: Any]).flatMap(NowPlaying.init(json:)) }
            .filter { seen.insert($0.sessionID).inserted }
            .prefix(Self.maxSessions)
            .sorted { first, second in
                let firstName = (first.appName ?? first.app?.bundleIdentifier ?? "").lowercased()
                let secondName = (second.appName ?? second.app?.bundleIdentifier ?? "").lowercased()
                if firstName != secondName { return firstName < secondName }
                return first.sessionID < second.sessionID
            }
        self.capturedAt = (json["capturedAt"] as? Double)
            .flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }
}

/// Immutable snapshot of one app's now-playing session, parsed from the entitled helper's JSON.
/// Several apps can hold a session at once; `NowPlayingSelection` decides which one is shown.
///
/// `Sendable` so a snapshot parsed on the background work queue can hop to the main
/// actor for publishing. All stored members are value types.
struct NowPlaying: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    /// Raw artwork image bytes (PNG/JPEG) as delivered by MediaRemote, if any.
    var artworkData: Data?
    /// Total track length in seconds (`0` when unknown).
    var duration: TimeInterval
    /// Whether the session is actively playing.
    var isPlaying: Bool

    /// The app that owns the session. `nil` when the helper could only read the app macOS
    /// elects as now-playing, which it reports without an identity.
    var app: NowPlayingApp?
    /// The owning app's display name, e.g. "Spotify".
    var appName: String?
    /// Whether macOS currently elects this session's app as the system now-playing app.
    var isElected: Bool

    /// Stable identity of the session across snapshots: its app, or a fixed value for the
    /// identity-less elected session.
    var sessionID: String {
        guard let app else { return "elected" }
        return "\(app.bundleIdentifier):\(app.processID)"
    }

    /// Stable identity for the current track, used to reuse cached artwork across the
    /// daemon's transient artwork drops (e.g. while scrubbing). Prefers MediaRemote's artwork
    /// identifier; falls back to the title/artist/album triple. Not part of equality.
    var trackIdentity: String

    /// Elapsed position captured at `elapsedTimestamp`. The live position is derived by
    /// advancing this by wall-clock time while playing — see `currentElapsed`.
    private var baseElapsed: TimeInterval
    /// Wall-clock instant at which `baseElapsed` was sampled.
    private var elapsedTimestamp: Date
    /// Playback rate (1.0 == normal speed, 0 == paused).
    private var playbackRate: Double

    /// When the session's position was last sampled. An app re-samples on play, pause, and seek,
    /// so the latest sample marks the session touched most recently.
    var positionSampledAt: Date { elapsedTimestamp }

    /// The live elapsed position, extrapolated from the sampled position using the
    /// playback rate and the time since the sample was taken. Clamped to `[0, duration]`.
    func currentElapsed(asOf now: Date = Date()) -> TimeInterval {
        guard isPlaying, playbackRate > 0 else {
            return min(max(baseElapsed, 0), duration > 0 ? duration : baseElapsed)
        }
        let advanced = baseElapsed + now.timeIntervalSince(elapsedTimestamp) * playbackRate
        if duration > 0 {
            return min(max(advanced, 0), duration)
        }
        return max(advanced, 0)
    }

    /// Fractional progress in `[0, 1]`, or `0` when the duration is unknown.
    func progress(asOf now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(currentElapsed(asOf: now) / duration, 0), 1)
    }

    /// Optimistically apply a play/pause toggle so the UI reflects it instantly, ahead of the
    /// daemon read that reconciles it. Re-bases the elapsed sample to `now` (using the live
    /// position under the *old* state) so extrapolation continues correctly from this point.
    mutating func setPlaying(_ playing: Bool, asOf now: Date = Date()) {
        baseElapsed = currentElapsed(asOf: now)
        elapsedTimestamp = now
        playbackRate = playing ? 1 : 0
        isPlaying = playing
    }

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying
            && lhs.baseElapsed == rhs.baseElapsed
            && lhs.playbackRate == rhs.playbackRate
            && lhs.artworkData == rhs.artworkData
            && lhs.app == rhs.app
            && lhs.appName == rhs.appName
            && lhs.isElected == rhs.isElected
    }

    /// Longest title/artist/album/app name kept. Another app sets these and they reach views;
    /// the helper applies the same bound.
    static let maxTextLength = 300

    /// A non-empty string field, cut to `maxTextLength`.
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return String(string.prefix(maxTextLength))
    }

    /// Parse one session object from the helper's JSON. Returns `nil` when it has no usable
    /// title, or names an app with a malformed identity — that identity addresses transport
    /// commands, so such a session is dropped. Numbers arrive as `NSNumber`, artwork as a base64
    /// string.
    init?(json: [String: Any]) {
        guard let title = Self.text(json["title"]) else { return nil }
        self.title = title
        self.artist = Self.text(json["artist"])
        self.album = Self.text(json["album"])

        if let b64 = json["artwork"] as? String, !b64.isEmpty {
            self.artworkData = Data(base64Encoded: b64)
        } else {
            self.artworkData = nil
        }

        self.trackIdentity = Self.makeIdentity(
            artworkIdentifier: (json["artworkIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            title: self.title, artist: self.artist, album: self.album)

        self.duration = (json["duration"] as? Double) ?? 0
        self.baseElapsed = (json["elapsed"] as? Double) ?? 0
        let rate = (json["rate"] as? Double) ?? 0
        self.playbackRate = rate

        // `baseElapsed` is the position the daemon sampled at `timestampEpoch`, not "now" — the
        // live position advances from there by wall-clock × rate (see `currentElapsed`). Many
        // players push that sample only at track start / seek, so honoring the real sample time
        // is what keeps the scrubber accurate; falling back to now would snap it back to the
        // stale sample on every poll.
        if let epoch = json["timestampEpoch"] as? Double, epoch > 0 {
            self.elapsedTimestamp = Date(timeIntervalSince1970: epoch)
        } else {
            self.elapsedTimestamp = Date()
        }
        self.isPlaying = (json["playing"] as? Bool) ?? (rate > 0)

        if json["bundleIdentifier"] != nil {
            guard let bundleIdentifier = json["bundleIdentifier"] as? String,
                  !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
                  let processID = json["processIdentifier"] as? Int,
                  processID > 0, processID <= Int(Int32.max) else {
                return nil
            }
            self.app = NowPlayingApp(bundleIdentifier: bundleIdentifier, processID: Int32(processID))
        } else {
            self.app = nil
        }
        self.appName = Self.text(json["appName"])
        self.isElected = (json["elected"] as? Bool) ?? false
    }

    /// Build a stable per-track identity. Prefers MediaRemote's artwork identifier (stable
    /// per item); falls back to the title/artist/album triple when it is absent.
    private static func makeIdentity(
        artworkIdentifier: String?, title: String, artist: String?, album: String?
    ) -> String {
        if let artworkIdentifier, !artworkIdentifier.isEmpty {
            return "id:\(artworkIdentifier)"
        }
        return "meta:\(title)\u{1F}\(artist ?? "")\u{1F}\(album ?? "")"
    }
}
