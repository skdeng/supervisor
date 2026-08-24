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
    /// The long-lived helper that pushes now-playing snapshots as they change. Primary source.
    private let stream = NowPlayingStream()
    /// Whether the stream is carrying updates. While it is, nothing else may spawn a helper on
    /// a timer or a notification — the stream already sees those changes.
    private var streamActive = false
    /// The adaptive poll, used only when the stream cannot run. See `startPolling()`.
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

    // MARK: Live spectrum (system-audio tap)

    /// Captures the system audio for the live spectrum bars + beat aura. Runs only while a
    /// track is actually playing (macOS shows a recording indicator while the tap is live).
    private let spectrumTap = SystemAudioTap()
    /// Latched when tap creation fails (permission denied or the tap stack is broken) so the
    /// poll doesn't retry creation every cycle. Cleared when the user re-enables the feature
    /// in Settings — that is the retry gesture.
    private var spectrumUnavailable = false
    /// Pending delayed tap stop after a pause, so a quick pause/resume doesn't tear the tap
    /// down only to immediately rebuild it.
    private var spectrumLingerTask: Task<Void, Never>?
    private var spectrumSettingCancellable: AnyCancellable?

    // MARK: CallSense transport ownership

    private let callMonitor = CallActivityMonitor.shared
    private var callSettingCancellable: AnyCancellable?
    private var callStateCancellable: AnyCancellable?
    private var callMonitorRetained = false
    private var lastCallActive = false
    private var autoPauseRequestID: UUID?
    private var autoPauseConfirmationTask: Task<Void, Never>?

    private enum AutoPausePhase {
        case awaitingPause
        case paused
    }

    private enum AutoPauseClaimDropReason: String {
        case manualChange = "manual change"
        case trackChange = "track change"
        case disabled
    }

    /// A pause this module issued, tied to both the now-playing process and track/session state.
    private struct AutoPauseClaim {
        let processID: pid_t?
        let trackIdentity: String
        var phase: AutoPausePhase
    }

    private var autoPauseClaim: AutoPauseClaim?

    init() {
        self.bridge = MediaRemoteBridge()
    }

    // MARK: NotchModule lifecycle

    func activate(_ context: NotchContext) {
        self.context = context
        self.canControl = bridge?.canSendCommands ?? false
        audioOutput.start()

        // Live spectrum: mirror the tap's state into the shared spectrum center (the compact
        // bars and the beat aura observe it) and latch failures so we stop retrying.
        spectrumTap.onStateChange = { [weak self] state in
            SpectrumCenter.shared.setCapturing(state == .running)
            guard let self else { return }
            if state == .unavailable {
                self.spectrumUnavailable = true
                self.reconcileSpectrumTap()
            }
        }
        // React to the Settings toggle live; re-enabling clears the failure latch (the retry
        // gesture after a denied permission that the user has since granted).
        spectrumSettingCancellable = SettingsStore.shared.$trueSpectrumEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.spectrumUnavailable = false
                    self.spectrumTap.resetAvailability()
                }
                self.reconcileSpectrumTap(spectrumEnabled: enabled)
            }

        callSettingCancellable = SettingsStore.shared.$callAutoPausesMusic
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.reconcileCallMonitoring(enabled: enabled)
            }

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
                    MainActor.assumeIsolated { self?.refreshFromSystemNotification() }
                }
                notificationObservers.append(observer)
            }
        }

        startStreaming()
    }

    func deactivate() {
        stream.stop()
        stream.onSnapshot = nil
        stream.onUnavailable = nil
        streamActive = false
        stopPolling()
        audioOutput.stop()
        spectrumSettingCancellable = nil
        callSettingCancellable = nil
        stopCallMonitoring()
        spectrumLingerTask?.cancel()
        spectrumLingerTask = nil
        spectrumTap.stop()
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
        reconcileAutoPauseClaim(with: reconciled)
        updateArtwork(for: reconciled)
        reconcileCompactVisibility()
        reconcileSpectrumTap()
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
        // Mirror into the shared spectrum center so the beat aura (core UI, which never
        // references modules) tints with the artwork too.
        SpectrumCenter.shared.setAccent(color)
    }

    /// Drive the system-audio tap from the current playback state: capture while a track is
    /// playing (and the feature is enabled and hasn't failed), linger 2 s across a pause so a
    /// quick resume doesn't rebuild the whole tap, and stop immediately when the feature is
    /// switched off (the recording indicator must honor the toggle without delay).
    private func reconcileSpectrumTap(spectrumEnabled: Bool? = nil) {
        let enabled = spectrumEnabled ?? SettingsStore.shared.trueSpectrumEnabled
        let playing = nowPlaying?.isPlaying == true
        spectrumTap.setExpectingAudio(playing)

        if enabled && !spectrumUnavailable && playing {
            spectrumLingerTask?.cancel()
            spectrumLingerTask = nil
            spectrumTap.start()
        } else if !enabled || spectrumUnavailable {
            spectrumLingerTask?.cancel()
            spectrumLingerTask = nil
            spectrumTap.stop()
        } else if spectrumLingerTask == nil {
            spectrumLingerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.spectrumLingerTask = nil
                let stillWanted = SettingsStore.shared.trueSpectrumEnabled
                    && !self.spectrumUnavailable
                    && self.nowPlaying?.isPlaying == true
                if !stillWanted {
                    self.spectrumTap.stop()
                }
            }
        }
    }

    /// Keep the UI in sync with media controlled anywhere on the system (Spotify, a browser,
    /// the Music app, hardware keys) from one long-lived helper that pushes snapshots as they
    /// change, so no process is spawned per update.
    private func startStreaming() {
        stream.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            // A snapshot arriving from the stream settles any read that was in flight.
            self.isReading = false
            self.finishRead(snapshot)
        }
        stream.onUnavailable = { [weak self] in
            guard let self else { return }
            // The helper is missing or cannot stay up. Fall back to spawning it per read.
            self.streamActive = false
            self.startPolling()
        }
        streamActive = true
        stream.start()
    }

    /// MediaRemote's change notifications are not reliably delivered to this ad-hoc-signed app,
    /// so they are a bonus signal rather than the dependable one. They are also redundant while
    /// the stream runs — the helper observes the same notifications in-process and re-reads on
    /// its own timer — so acting on them here would spawn a second helper for no new
    /// information.
    private func refreshFromSystemNotification() {
        guard !streamActive else { return }
        refresh()
    }

    /// Steady poll that keeps the UI in sync when the streaming helper is unavailable. The
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

    // MARK: CallSense auto-pause

    private func reconcileCallMonitoring(enabled: Bool) {
        if enabled {
            guard !callMonitorRetained else { return }
            callMonitorRetained = true
            lastCallActive = false
            callMonitor.retain()
            callStateCancellable = Publishers.CombineLatest(
                callMonitor.$isCameraInUse,
                callMonitor.$isMicInUse
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleCallActivityChange()
            }
        } else {
            stopCallMonitoring()
        }
    }

    private func stopCallMonitoring() {
        callStateCancellable = nil
        clearAutoPauseClaim(droppedBecause: .disabled)
        lastCallActive = false
        guard callMonitorRetained else { return }
        callMonitorRetained = false
        callMonitor.release()
    }

    private func handleCallActivityChange() {
        let callActive = callMonitor.isCallLikely
        guard callActive != lastCallActive else { return }
        lastCallActive = callActive
        if callActive {
            beginAutoPauseIfNeeded()
        } else {
            resumeAutoPausedMediaIfEligible()
        }
    }

    private func beginAutoPauseIfNeeded() {
        guard SettingsStore.shared.callAutoPausesMusic,
              let bridge,
              let snapshot = nowPlaying,
              snapshot.isPlaying else {
            return
        }

        let requestID = UUID()
        let trackIdentity = snapshot.trackIdentity
        autoPauseRequestID = requestID
        bridge.fetchNowPlayingApplicationPID(on: .main) { [weak self] processID in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completeAutoPauseRequest(
                        requestID: requestID,
                        processID: processID,
                        trackIdentity: trackIdentity
                    )
                }
            }
        }
    }

    private func completeAutoPauseRequest(
        requestID: UUID,
        processID: pid_t?,
        trackIdentity: String
    ) {
        guard autoPauseRequestID == requestID,
              SettingsStore.shared.callAutoPausesMusic,
              callMonitor.isCallLikely,
              let bridge,
              let snapshot = nowPlaying,
              snapshot.trackIdentity == trackIdentity,
              snapshot.isPlaying else {
            if autoPauseRequestID == requestID {
                autoPauseRequestID = nil
            }
            return
        }

        autoPauseRequestID = nil
        clearExpectedPlaying()
        guard bridge.send(.pause) else { return }
        autoPauseClaim = AutoPauseClaim(
            processID: processID,
            trackIdentity: trackIdentity,
            phase: .awaitingPause
        )
        AppLog.notice(.media, "auto-pause issued")

        autoPauseConfirmationTask?.cancel()
        autoPauseConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled,
                  self.autoPauseClaim?.phase == .awaitingPause else {
                return
            }
            self.clearAutoPauseClaim(droppedBecause: .manualChange)
        }
        refreshAfterTransportCommand()
    }

    /// Keep the claim only while its original now-playing session reaches and remains paused.
    private func reconcileAutoPauseClaim(with snapshot: NowPlaying?) {
        guard var claim = autoPauseClaim else { return }
        guard let snapshot,
              snapshot.trackIdentity == claim.trackIdentity else {
            clearAutoPauseClaim(droppedBecause: .trackChange)
            return
        }

        switch claim.phase {
        case .awaitingPause:
            if !snapshot.isPlaying {
                claim.phase = .paused
                autoPauseClaim = claim
                autoPauseConfirmationTask?.cancel()
                autoPauseConfirmationTask = nil
            }
        case .paused:
            if snapshot.isPlaying {
                clearAutoPauseClaim(droppedBecause: .manualChange)
            }
        }
    }

    private func resumeAutoPausedMediaIfEligible() {
        autoPauseRequestID = nil
        autoPauseConfirmationTask?.cancel()
        autoPauseConfirmationTask = nil

        guard let claim = autoPauseClaim,
              claim.phase == .paused,
              let snapshot = nowPlaying,
              snapshot.trackIdentity == claim.trackIdentity,
              !snapshot.isPlaying,
              let bridge else {
            clearAutoPauseClaim(droppedBecause: autoPauseClaimDropReason(for: nowPlaying))
            return
        }

        let requestID = UUID()
        autoPauseRequestID = requestID
        bridge.fetchNowPlayingApplicationPID(on: .main) { [weak self] processID in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completeAutoResumeRequest(
                        requestID: requestID,
                        processID: processID,
                        bridge: bridge
                    )
                }
            }
        }
    }

    private func completeAutoResumeRequest(
        requestID: UUID,
        processID: pid_t?,
        bridge: MediaRemoteBridge
    ) {
        guard autoPauseRequestID == requestID,
              SettingsStore.shared.callAutoPausesMusic,
              !callMonitor.isCallLikely,
              let claim = autoPauseClaim,
              claim.phase == .paused,
              claim.processID == processID,
              let snapshot = nowPlaying,
              snapshot.trackIdentity == claim.trackIdentity,
              !snapshot.isPlaying else {
            if autoPauseRequestID == requestID {
                clearAutoPauseClaim(
                    droppedBecause: autoPauseClaimDropReason(for: nowPlaying)
                )
            }
            return
        }

        clearAutoPauseClaim()
        if bridge.send(.play) {
            AppLog.notice(.media, "auto-resume issued")
            refreshAfterTransportCommand()
        }
    }

    private func autoPauseClaimDropReason(
        for snapshot: NowPlaying?
    ) -> AutoPauseClaimDropReason {
        if !SettingsStore.shared.callAutoPausesMusic {
            return .disabled
        }
        guard let claim = autoPauseClaim,
              let snapshot,
              snapshot.trackIdentity == claim.trackIdentity else {
            return .trackChange
        }
        return .manualChange
    }

    private func clearAutoPauseClaim(
        droppedBecause reason: AutoPauseClaimDropReason? = nil
    ) {
        let hadClaim = autoPauseClaim != nil
        autoPauseRequestID = nil
        autoPauseConfirmationTask?.cancel()
        autoPauseConfirmationTask = nil
        autoPauseClaim = nil
        if hadClaim, let reason {
            AppLog.notice(.media, "auto-pause claim dropped: \(reason.rawValue)")
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

    private func refreshAfterTransportCommand() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func togglePlayPause() {
        if callMonitor.isCallLikely {
            clearAutoPauseClaim(droppedBecause: .manualChange)
        }
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
    func nextTrack() {
        clearExpectedPlaying()
        clearAutoPauseClaim(droppedBecause: .trackChange)
        sendCommand(.nextTrack)
    }

    func previousTrack() {
        clearExpectedPlaying()
        clearAutoPauseClaim(droppedBecause: .trackChange)
        sendCommand(.previousTrack)
    }
}
