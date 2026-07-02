import AppKit
import Combine
import SwiftUI

/// MusicVisor — the system-wide now-playing module.
///
/// Reads the active media session's metadata through `NowPlayingReader` (an entitled helper,
/// since macOS gates direct now-playing reads for third-party apps) and exposes it as
/// `@Published` state. Transport commands still go straight through the private `MediaRemote`
/// framework via `MediaRemoteBridge` (commands remain permitted). It renders:
///   - **compactLeading**: a tiny album-art thumbnail (left of the notch).
///   - **compactTrailing**: an animated audio-bars equalizer (right of the notch).
///   - **expandedSection**: large artwork, title/artist, a live scrubber, and transport.
///
/// All UI state is `@MainActor`-isolated; the helper read runs off the main actor and hops
/// back to publish.
@MainActor
final class MediaModule: NotchModule, ObservableObject {
    let moduleID = "media"
    let displayName = "MusicVisor"
    let order = 10

    /// The current now-playing snapshot, or `nil` when nothing is loaded. Drives all UI.
    @Published private(set) var nowPlaying: NowPlaying?

    /// Decoded artwork for the current track. Cached and decoded exactly once per track so
    /// SwiftUI view bodies read a ready `NSImage` instead of re-parsing the artwork bytes on
    /// every render. `nil` when the current track has no artwork.
    @Published private(set) var artworkImage: NSImage?

    /// A vibrant dominant color drawn from the current artwork, used to tint the compact
    /// equalizer bars. Falls back to white when there's no artwork.
    @Published private(set) var artworkAccent: Color = MediaArtworkColor.fallback

    /// Whether transport commands are available (MediaRemote `SendCommand` resolved).
    @Published private(set) var canControl = false

    /// System audio output route (current device + available devices + switching). Observed by
    /// the expanded media section's output selector.
    let audioOutput = AudioOutputController()

    private var context: NotchContext?
    private let bridge: MediaRemoteBridge?
    /// Reads now-playing info through the entitled helper; safe to use off the main actor.
    nonisolated let reader = NowPlayingReader()

    private var notificationObservers: [NSObjectProtocol] = []
    /// The steady adaptive poll that keeps the UI in sync with media controlled elsewhere
    /// (faster while playing, slower when paused/idle). See `startPolling()`.
    private var pollTask: Task<Void, Never>?
    /// Guards against overlapping helper reads piling up under a burst of notifications.
    private var isReading = false
    /// Set when a refresh is requested while a read is already in flight. The in-flight read
    /// runs one more read on completion, so a coalesced refresh (e.g. right after a transport
    /// command) is never silently dropped and the UI always reaches the latest state.
    private var pendingRefresh = false

    /// After an optimistic play/pause toggle, the play state we expect the daemon to report,
    /// and the track it applies to. While set, reads that still report the old state (the
    /// command hasn't settled yet) are overridden to this value so the button can't flicker
    /// back. Cleared once a read confirms it, the track changes, or a timeout elapses.
    private var expectedPlaying: Bool?
    private var expectedTrackIdentity: String?
    private var expectedPlayingTimeout: Task<Void, Never>?

    /// Last artwork bytes seen, keyed by track identity. MediaRemote transiently drops the
    /// artwork from a poll (e.g. while scrubbing) even though the track is unchanged; we
    /// re-inject the cached bytes so the UI artwork never flickers off mid-track.
    private var cachedArtwork: (identity: String, data: Data)?
    /// The decoded `NSImage` and its extracted accent color, keyed by track identity so they are
    /// rebuilt only when the track actually changes (not on every poll/re-render).
    private var decodedArtwork: (identity: String, image: NSImage, accent: Color)?

    /// Tracks whether a compact contribution is currently shown, so we only ask the engine
    /// to re-lay-out the pill when that visibility actually flips.
    private var hadCompactContribution = false

    init() {
        self.bridge = MediaRemoteBridge()
    }

    // MARK: NotchModule lifecycle

    func activate(_ context: NotchContext) {
        self.context = context
        self.canControl = bridge?.canSendCommands ?? false
        audioOutput.start()

        // MediaRemote still broadcasts now-playing change notifications even though info
        // reads are gated; subscribe for instant updates on track/state changes.
        if let bridge {
            bridge.registerForNotifications(on: DispatchQueue.global(qos: .utility))
            let center = NotificationCenter.default
            let names = [
                MediaRemoteBridge.NotificationName.infoDidChange,
                MediaRemoteBridge.NotificationName.isPlayingDidChange,
                MediaRemoteBridge.NotificationName.nowPlayingAppDidChange,
            ]
            for name in names {
                let observer = center.addObserver(
                    forName: Notification.Name(name),
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // Delivered on the main queue (registered with `queue: .main`), so it is
                    // safe to assert main-actor isolation and call the @MainActor refresh.
                    MainActor.assumeIsolated { self?.refresh() }
                }
                notificationObservers.append(observer)
            }
        }

        // Keep the UI in sync with media controlled anywhere on the system via a steady,
        // self-adapting poll (notifications alone are unreliable for this app). The change
        // notifications above still trigger an immediate refresh when they do fire.
        startPolling()
    }

    func deactivate() {
        stopPolling()
        audioOutput.stop()
        // Clear the read latch so a teardown mid-read can't leave it stuck (which would
        // silently freeze all future refreshes if the module were re-activated).
        isReading = false
        pendingRefresh = false
        clearExpectedPlaying()
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
        bridge?.unregister()
        context = nil
    }

    // MARK: UI contributions

    /// Album-art thumbnail flanks the notch on the left; the audio bars flank it on the right,
    /// so the now-playing indicator reads as centered around the notch.
    func compactLeading() -> AnyView? {
        guard nowPlaying != nil else { return nil }
        return AnyView(MediaArtworkCompactView(module: self))
    }

    func compactTrailing() -> AnyView? {
        guard nowPlaying != nil else { return nil }
        return AnyView(MediaBarsCompactView(module: self))
    }

    /// Only contribute a panel section when something is actually playing — no
    /// "Nothing playing" placeholder.
    func expandedSection() -> AnyView? {
        guard nowPlaying != nil else { return nil }
        return AnyView(MediaExpandedView(module: self))
    }

    // MARK: Refresh pipeline

    /// Read the now-playing snapshot via the entitled helper off the main actor, then publish
    /// on the main actor. Coalesced so a burst of notifications can't stack up helper runs.
    func refresh() {
        guard !isReading else {
            // A read is already running; remember to read again when it finishes so this
            // request isn't lost to coalescing.
            pendingRefresh = true
            return
        }
        isReading = true
        pendingRefresh = false
        Task.detached(priority: .utility) { [weak self, reader] in
            let snapshot = reader.read()
            await self?.finishRead(snapshot)
        }
    }

    private func finishRead(_ snapshot: NowPlaying?) {
        isReading = false
        var reconciled = snapshot.map(reconcileArtwork)

        // While an optimistic play/pause is pending, don't let a not-yet-settled read flip the
        // UI back: hold the expected state until a read confirms it (or the track changes).
        if let expected = expectedPlaying {
            if let read = reconciled, read.trackIdentity == expectedTrackIdentity {
                if read.isPlaying == expected {
                    clearExpectedPlaying()           // daemon caught up — accept the read as-is
                } else {
                    var held = read                  // stale read — keep the optimistic state
                    held.setPlaying(expected)
                    reconciled = held
                }
            } else {
                clearExpectedPlaying()               // track changed / stopped — expectation void
            }
        }

        nowPlaying = reconciled
        updateArtwork(for: reconciled)
        reconcileCompactVisibility()
        // Honor a refresh that was requested while this read was in flight.
        if pendingRefresh {
            pendingRefresh = false
            refresh()
        }
    }

    /// Begin holding an optimistic play state for the given track until a read confirms it.
    private func setExpectedPlaying(_ playing: Bool, track: String?) {
        expectedPlaying = playing
        expectedTrackIdentity = track
        expectedPlayingTimeout?.cancel()
        expectedPlayingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.clearExpectedPlaying()
        }
    }

    private func clearExpectedPlaying() {
        expectedPlaying = nil
        expectedTrackIdentity = nil
        expectedPlayingTimeout?.cancel()
        expectedPlayingTimeout = nil
    }

    /// Decode the artwork once per track and cache it, so views read a ready `NSImage`. The
    /// bytes are stable per track (see `reconcileArtwork`), so this is a cache hit across the
    /// repeated polls of a single track and only re-decodes when the track changes.
    private func updateArtwork(for snapshot: NowPlaying?) {
        guard let snapshot, let data = snapshot.artworkData, !data.isEmpty else {
            decodedArtwork = nil
            if artworkImage != nil { artworkImage = nil }
            setAccent(MediaArtworkColor.fallback)
            return
        }
        if let cached = decodedArtwork, cached.identity == snapshot.trackIdentity {
            if artworkImage !== cached.image { artworkImage = cached.image }
            setAccent(cached.accent)
            return
        }
        guard let image = NSImage(data: data) else {
            decodedArtwork = nil
            if artworkImage != nil { artworkImage = nil }
            setAccent(MediaArtworkColor.fallback)
            return
        }
        let accent = MediaArtworkColor.dominant(of: image) ?? MediaArtworkColor.fallback
        decodedArtwork = (snapshot.trackIdentity, image, accent)
        if artworkImage !== image { artworkImage = image }
        setAccent(accent)
    }

    private func setAccent(_ color: Color) {
        if artworkAccent != color { artworkAccent = color }
    }

    /// Steady poll that keeps the UI in sync with media controlled elsewhere (Spotify, a
    /// browser, the Music app, hardware keys). MediaRemote's change notifications are not
    /// reliably delivered to this ad-hoc-signed app, so a poll is the dependable signal. The
    /// cadence adapts: fast while a track is actively playing (the scrubber position needs to
    /// advance), slower when paused/idle (we only need to notice external changes reasonably
    /// soon). Idle reads are cheap because the helper early-exits when nothing is playing.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                let playing = (self?.nowPlaying?.isPlaying == true)
                try? await Task.sleep(for: .seconds(playing ? 2 : 4))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-inject cached artwork when the daemon transiently drops it from a poll, and refresh
    /// the cache whenever fresh artwork arrives. Keyed by track identity so artwork never
    /// leaks across tracks.
    private func reconcileArtwork(_ snapshot: NowPlaying) -> NowPlaying {
        var snapshot = snapshot
        if let data = snapshot.artworkData, !data.isEmpty {
            cachedArtwork = (snapshot.trackIdentity, data)
        } else if let cached = cachedArtwork, cached.identity == snapshot.trackIdentity {
            snapshot.artworkData = cached.data
        } else {
            cachedArtwork = nil
        }
        return snapshot
    }

    /// Tell the engine to re-lay-out the pill only when our compact contribution's presence
    /// changes (track appears / disappears), per the contract.
    private func reconcileCompactVisibility() {
        let hasContribution = nowPlaying != nil
        if hasContribution != hadCompactContribution {
            hadCompactContribution = hasContribution
            context?.setNeedsCompactRefresh()
        }
    }

    // MARK: Transport commands

    /// Send a transport command (still permitted via MediaRemote), then refresh shortly after
    /// so the UI reflects the new state even before a change notification arrives.
    private func sendCommand(_ command: MediaRemoteBridge.Command) {
        guard let bridge else { return }
        Task.detached(priority: .userInitiated) { [weak self, bridge] in
            bridge.send(command)
            try? await Task.sleep(for: .milliseconds(250))
            await self?.refresh()
        }
    }

    func togglePlayPause() {
        // Optimistically flip the play state so the button, scrubber, and poll respond
        // instantly; the post-command read reconciles with the daemon's actual state.
        if var snapshot = nowPlaying {
            let target = !snapshot.isPlaying
            snapshot.setPlaying(target)
            nowPlaying = snapshot
            setExpectedPlaying(target, track: snapshot.trackIdentity)
        }
        sendCommand(.togglePlayPause)
    }

    // Track changes invalidate any pending play/pause expectation (new track, new state).
    func nextTrack() { clearExpectedPlaying(); sendCommand(.nextTrack) }
    func previousTrack() { clearExpectedPlaying(); sendCommand(.previousTrack) }
}
