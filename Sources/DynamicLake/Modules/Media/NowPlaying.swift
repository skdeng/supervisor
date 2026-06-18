import AppKit
import Foundation

/// Immutable snapshot of the system-wide now-playing session, parsed from the
/// MediaRemote info dict. A `nil` `NowPlaying` means no track is loaded in any app.
///
/// `Sendable` so a snapshot parsed on the background work queue can hop to the main
/// actor for publishing. All stored members are value types (`String`, `Data`,
/// `TimeInterval`, `Bool`, `Date`).
struct NowPlaying: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    /// Raw artwork image bytes (PNG/JPEG) as delivered by MediaRemote, if any.
    var artworkData: Data?
    /// Total track length in seconds (`0` when unknown).
    var duration: TimeInterval
    /// Whether the session is actively playing (playback rate > 0).
    var isPlaying: Bool

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

    /// Decoded artwork, lazily produced from `artworkData`. Not part of equality.
    var artworkImage: NSImage? {
        guard let artworkData else { return nil }
        return NSImage(data: artworkData)
    }

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

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying
            && lhs.baseElapsed == rhs.baseElapsed
            && lhs.playbackRate == rhs.playbackRate
            && lhs.artworkData == rhs.artworkData
    }

    /// Parse a MediaRemote info dict into a `NowPlaying`. Returns `nil` when the dict has
    /// no usable title (no active session).
    init?(infoDict info: [String: Any], isPlayingHint: Bool?) {
        guard let title = info[MediaRemoteBridge.InfoKey.title] as? String,
              !title.isEmpty else {
            return nil
        }
        self.title = title
        self.artist = (info[MediaRemoteBridge.InfoKey.artist] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.album = (info[MediaRemoteBridge.InfoKey.album] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.artworkData = info[MediaRemoteBridge.InfoKey.artworkData] as? Data
        self.trackIdentity = Self.makeIdentity(
            artworkIdentifier: info[MediaRemoteBridge.InfoKey.artworkIdentifier] as? String,
            title: title, artist: self.artist, album: self.album)

        self.duration = (info[MediaRemoteBridge.InfoKey.duration] as? NSNumber)?.doubleValue ?? 0
        self.baseElapsed = (info[MediaRemoteBridge.InfoKey.elapsedTime] as? NSNumber)?.doubleValue ?? 0

        let rate = (info[MediaRemoteBridge.InfoKey.playbackRate] as? NSNumber)?.doubleValue ?? 0
        self.playbackRate = rate

        // MediaRemote stamps when elapsed was measured; honor it so the scrubber stays
        // accurate even if the info dict was fetched a moment ago. Fall back to now.
        if let stamp = info[MediaRemoteBridge.InfoKey.timestamp] as? Date {
            self.elapsedTimestamp = stamp
        } else {
            self.elapsedTimestamp = Date()
        }

        // Prefer the explicit isPlaying signal; otherwise infer from the playback rate.
        self.isPlaying = isPlayingHint ?? (rate > 0)
    }

    /// Parse the JSON emitted by `NowPlayingReader`'s entitled helper. Returns `nil` when no
    /// usable title is present (no active session). Numbers arrive as `NSNumber`, artwork as
    /// a base64 string.
    init?(json: [String: Any]) {
        guard let title = json["title"] as? String, !title.isEmpty else { return nil }
        self.title = title
        self.artist = (json["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.album = (json["album"] as? String).flatMap { $0.isEmpty ? nil : $0 }

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
        self.elapsedTimestamp = Date()
        self.isPlaying = rate > 0
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
