import AppKit
import Combine
import SwiftUI

/// MusicVisor — the system-wide now-playing module.
///
/// Reads every app's media session through an entitled helper (`NowPlayingStream`, with
/// `NowPlayingReader` for one-off reads — macOS gates direct now-playing reads for third-party
/// apps), presents the one `NowPlayingSelection` picks, and exposes it as `@Published` state.
/// Transport commands go straight through the private `MediaRemote` framework via
/// `MediaRemoteBridge`, addressed to the presented session's app. It renders:
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

    /// The presented session, or `nil` when no app has one. Drives the pill and the section.
    @Published private(set) var nowPlaying: NowPlaying?

    /// Every app's session, in a stable order. Drives the session list.
    @Published private(set) var sessions: [NowPlaying] = []

    /// Decoded artwork for the presented session. Cached and decoded exactly once per track so
    /// SwiftUI view bodies read a ready `NSImage` instead of re-parsing the artwork bytes on
    /// every render. `nil` when the track has no artwork.
    @Published private(set) var artworkImage: NSImage?

    /// Decoded artwork for each session that has any, keyed by `sessionID`.
    @Published private(set) var sessionArtwork: [String: NSImage] = [:]

    /// A vibrant dominant color drawn from the current artwork, used to tint the compact
    /// equalizer bars. Falls back to white when there's no artwork.
    @Published private(set) var artworkAccent: Color = MediaArtworkColor.fallback

    /// Whether transport commands can reach the presented session.
    @Published private(set) var canControl = false

    /// System audio output route (current device + available devices + switching). Observed by
    /// the expanded media section's output selector.
    let audioOutput = AudioOutputController()

    /// Identifies the session list among the sheet's takeovers.
    static let sessionsTakeoverID = "media.sessions"

    private var context: NotchContext?
    private let bridge: MediaRemoteBridge?
    /// Which of `sessions` is presented.
    private var selection = NowPlayingSelection()
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
    /// When the newest capture applied so far was taken. The stream and a one-shot read run in
    /// separate helpers, so a capture taken earlier can arrive later; applying it would roll the
    /// state back, and the stream stays silent until something changes again.
    private var lastCaptureDate: Date?
    /// Set when a refresh is requested while a read is already in flight. The in-flight read
    /// runs one more read on completion, so a coalesced refresh (e.g. right after a transport
    /// command) is never silently dropped and the UI always reaches the latest state.
    private var pendingRefresh = false

    /// The play state an optimistic play/pause toggle expects the daemon to report for one
    /// session's track.
    private struct ExpectedPlaying {
        let sessionID: String
        let trackIdentity: String
        let playing: Bool
    }

    /// After an optimistic play/pause toggle, the state the daemon is expected to report. While
    /// set, reads that still report the old state (the command hasn't settled yet) are
    /// overridden to this value so the button can't flicker back. Cleared once a read confirms
    /// it, the track changes, or a timeout elapses.
    private var expectedPlaying: ExpectedPlaying?
    private var expectedPlayingTimeout: Task<Void, Never>?

    /// Last artwork bytes seen for each session, with the track they belong to. MediaRemote
    /// transiently drops the artwork from a read (e.g. while scrubbing) even though the track is
    /// unchanged; the cached bytes are re-injected so the artwork never flickers off mid-track.
    private var cachedArtwork: [String: (identity: String, data: Data)] = [:]
    /// Each session's decoded `NSImage`, with the track it belongs to, so it is rebuilt only
    /// when the track changes. The accent color is extracted on first presentation.
    private var decodedArtwork: [String: (identity: String, image: NSImage, accent: Color?)] = [:]

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
    /// Whether any other process is producing sound on this Mac; runs only while the session is
    /// playing and the feature can use the answer.
    private let localOutput = LocalAudioOutputMonitor()
    /// When the session began reporting playing while the intent stayed `.linger` (no sound
    /// produced here), or `nil` outside such a stretch.
    private var silentPlayingSince: Date?
    /// Pending tap start counting down `SpectrumTapAction.settle`.
    private var spectrumStartTask: Task<Void, Never>?

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

    /// A pause this module issued, tied to the session it paused, that session's process, and
    /// its track.
    private struct AutoPauseClaim {
        let sessionID: String
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.spectrumUnavailable = false
                    self.spectrumTap.resetAvailability()
                }
                self.reconcileSpectrumTap()
            }
        localOutput.onChange = { [weak self] in self?.reconcileSpectrumTap() }
        reconcileSpectrumTap()

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
        SheetTakeoverCenter.shared.dismiss(id: Self.sessionsTakeoverID)
        stream.stop()
        stream.onCapture = nil
        stream.onUnavailable = nil
        streamActive = false
        stopPolling()
        audioOutput.stop()
        spectrumSettingCancellable = nil
        callSettingCancellable = nil
        stopCallMonitoring()
        spectrumLingerTask?.cancel()
        spectrumLingerTask = nil
        spectrumStartTask?.cancel()
        spectrumStartTask = nil
        localOutput.onChange = nil
        localOutput.stop()
        silentPlayingSince = nil
        spectrumTap.setExpectingAudio(false)
        spectrumTap.stop()
        // Clear the read latch so a teardown mid-read can't leave it stuck (which would
        // silently freeze all future refreshes if the module were re-activated).
        isReading = false
        pendingRefresh = false
        clearExpectedPlaying()
        // Start the next activation from nothing, so it never shows sessions that have since
        // ended.
        selection = NowPlayingSelection()
        lastCaptureDate = nil
        cachedArtwork.removeAll()
        decodedArtwork.removeAll()
        sessions = []
        sessionArtwork = [:]
        nowPlaying = nil
        artworkImage = nil
        canControl = false
        hadCompactContribution = false
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

    /// Read every session via the entitled helper off the main actor, then publish on the main
    /// actor. Coalesced so a burst of notifications can't stack up helper runs.
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
            let capture = reader.read()
            await self?.finishRead(capture)
        }
    }

    /// Apply a capture. A read that produced none (`nil`), or one taken before a capture already
    /// applied, leaves the presented state as it is.
    private func finishRead(_ capture: NowPlayingCapture?) {
        isReading = false
        defer {
            // Honor a refresh that was requested while this read was in flight.
            if pendingRefresh {
                pendingRefresh = false
                refresh()
            }
        }
        guard let capture else { return }
        if let capturedAt = capture.capturedAt {
            if let lastCaptureDate, capturedAt < lastCaptureDate { return }
            lastCaptureDate = capturedAt
        }
        var sessions = reconcileArtwork(capture.sessions)

        // While an optimistic play/pause is pending, don't let a not-yet-settled read flip the
        // UI back: hold the expected state until a read confirms it (or the track changes).
        if let expected = expectedPlaying {
            if let index = sessions.firstIndex(where: {
                $0.sessionID == expected.sessionID && $0.trackIdentity == expected.trackIdentity
            }) {
                if sessions[index].isPlaying == expected.playing {
                    clearExpectedPlaying()           // daemon caught up — accept the read as-is
                } else {
                    sessions[index].setPlaying(expected.playing)   // stale read — hold it
                }
            } else {
                clearExpectedPlaying()               // track changed / stopped — expectation void
            }
        }

        present(sessions)
    }

    /// Publish `sessions` and whichever of them the selection presents.
    private func present(_ sessions: [NowPlaying]) {
        let chosen = selection.update(with: sessions)
        if chosen?.sessionID != nowPlaying?.sessionID {
            AppLog.notice(
                .media,
                "presented session -> \(chosen?.app?.bundleIdentifier ?? (chosen == nil ? "none" : "elected")) of \(sessions.count)"
            )
        }
        if self.sessions != sessions { self.sessions = sessions }
        nowPlaying = chosen
        let controllable = chosen.map { bridge?.canSend(to: $0) ?? false } ?? false
        if canControl != controllable { canControl = controllable }
        reconcileAutoPauseClaim(with: sessions)
        updateArtwork(for: sessions, presented: chosen)
        reconcileCompactVisibility()
        reconcileSpectrumTap()
    }

    /// Present the session the user picked, and keep presenting it until it ends or a different
    /// session starts playing.
    func select(sessionID: String) {
        selection.pin(sessionID)
        present(sessions)
    }

    /// Begin holding an optimistic play state for `session`'s track until a read confirms it.
    private func setExpectedPlaying(_ playing: Bool, for session: NowPlaying) {
        expectedPlaying = ExpectedPlaying(
            sessionID: session.sessionID, trackIdentity: session.trackIdentity, playing: playing)
        expectedPlayingTimeout?.cancel()
        expectedPlayingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            // No read confirmed the toggle, so the command may not have taken effect. The
            // stream reports only changes, so the real state has to be read back.
            self.clearExpectedPlaying()
            self.refresh()
        }
    }

    private func clearExpectedPlaying() {
        expectedPlaying = nil
        expectedPlayingTimeout?.cancel()
        expectedPlayingTimeout = nil
    }

    /// Decode each session's artwork once per track and cache it, so views read a ready
    /// `NSImage`. The bytes are stable per track (see `reconcileArtwork`), so this is a cache hit
    /// across the repeated reads of a track and only re-decodes when a track changes. The
    /// dominant color is extracted only for a session that gets presented.
    private func updateArtwork(for sessions: [NowPlaying], presented: NowPlaying?) {
        var decoded: [String: (identity: String, image: NSImage, accent: Color?)] = [:]
        for session in sessions {
            guard let data = session.artworkData, !data.isEmpty else { continue }
            if let cached = decodedArtwork[session.sessionID], cached.identity == session.trackIdentity {
                decoded[session.sessionID] = cached
            } else if let image = MediaArtworkDecoder.image(from: data) {
                decoded[session.sessionID] = (session.trackIdentity, image, nil)
            }
        }

        if let presented, var entry = decoded[presented.sessionID] {
            let accent = entry.accent
                ?? MediaArtworkColor.dominant(of: entry.image)
                ?? MediaArtworkColor.fallback
            entry.accent = accent
            decoded[presented.sessionID] = entry
            if artworkImage !== entry.image { artworkImage = entry.image }
            setAccent(accent)
        } else {
            if artworkImage != nil { artworkImage = nil }
            setAccent(MediaArtworkColor.fallback)
        }
        decodedArtwork = decoded

        let unchanged = decoded.count == sessionArtwork.count
            && decoded.allSatisfy { sessionArtwork[$0.key] === $0.value.image }
        if !unchanged { sessionArtwork = decoded.mapValues(\.image) }
    }

    private func setAccent(_ color: Color) {
        if artworkAccent != color { artworkAccent = color }
        // Mirror into the shared spectrum center so the beat aura (core UI, which never
        // references modules) tints with the artwork too.
        SpectrumCenter.shared.setAccent(color)
    }

    /// Drive the system-audio tap from the current playback state: capture while a track is
    /// playing and some process here is producing sound (and the feature is enabled and hasn't
    /// failed), linger 2 s across a pause so a quick resume doesn't rebuild the whole tap, and
    /// stop immediately when the feature is switched off (the recording indicator must honor
    /// the toggle without delay). The local-output monitor runs only while its answer can
    /// matter, so a paused session or a disabled feature registers no audio listeners.
    private func reconcileSpectrumTap() {
        let enabled = SettingsStore.shared.trueSpectrumEnabled
        let playing = nowPlaying?.isPlaying == true
        if enabled && !spectrumUnavailable && playing {
            localOutput.start()
        } else {
            localOutput.stop()
        }

        let intent = currentSpectrumIntent()
        spectrumTap.setExpectingAudio(intent == .capture)
        let now = Date()
        let silentPlayingFor = silentPlayingSince.map { now.timeIntervalSince($0) }
        let action = SpectrumTapAction.resolve(
            intent: intent,
            silentPlayingFor: silentPlayingFor,
            settlePending: spectrumStartTask != nil
        )

        switch action {
        case .start:
            spectrumLingerTask?.cancel()
            spectrumLingerTask = nil
            spectrumStartTask?.cancel()
            spectrumStartTask = nil
            spectrumTap.start()
        case .settleThenStart:
            spectrumLingerTask?.cancel()
            spectrumLingerTask = nil
            if spectrumStartTask == nil {
                spectrumStartTask = Task { [weak self] in
                    try? await Task.sleep(for: SpectrumTapAction.settle)
                    guard let self, !Task.isCancelled else { return }
                    self.spectrumStartTask = nil
                    if self.currentSpectrumIntent() == .capture {
                        self.spectrumTap.start()
                    }
                }
            }
        case .stop:
            spectrumLingerTask?.cancel()
            spectrumLingerTask = nil
            spectrumStartTask?.cancel()
            spectrumStartTask = nil
            spectrumTap.stop()
        case .linger:
            spectrumStartTask?.cancel()
            spectrumStartTask = nil
            if spectrumLingerTask == nil {
                spectrumLingerTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    self.spectrumLingerTask = nil
                    if self.currentSpectrumIntent() != .capture {
                        self.spectrumTap.stop()
                    }
                }
            }
        }

        if intent == .linger && playing {
            if silentPlayingSince == nil { silentPlayingSince = now }
        } else {
            silentPlayingSince = nil
        }
    }

    private func currentSpectrumIntent() -> SpectrumTapIntent {
        SpectrumTapIntent.resolve(
            enabled: SettingsStore.shared.trueSpectrumEnabled,
            unavailable: spectrumUnavailable,
            playing: nowPlaying?.isPlaying == true,
            localOutputRunning: localOutput.isAnyProcessRunningOutput
        )
    }

    /// Keep the UI in sync with media controlled anywhere on the system (Spotify, a browser,
    /// the Music app, hardware keys) from one long-lived helper that pushes snapshots as they
    /// change, so no process is spawned per update.
    private func startStreaming() {
        stream.onCapture = { [weak self] capture in
            self?.finishRead(capture)
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

    /// Re-inject cached artwork into a session whose read transiently dropped it, and refresh
    /// the cache whenever fresh artwork arrives. Each entry is tied to its track, so artwork
    /// never leaks across tracks, and entries for sessions that ended are dropped.
    private func reconcileArtwork(_ sessions: [NowPlaying]) -> [NowPlaying] {
        var cache: [String: (identity: String, data: Data)] = [:]
        let reconciled = sessions.map { session -> NowPlaying in
            var session = session
            if let data = session.artworkData, !data.isEmpty {
                cache[session.sessionID] = (session.trackIdentity, data)
            } else if let cached = cachedArtwork[session.sessionID],
                      cached.identity == session.trackIdentity {
                session.artworkData = cached.data
                cache[session.sessionID] = cached
            }
            return session
        }
        cachedArtwork = cache
        return reconciled
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
        let sessionID = snapshot.sessionID
        let trackIdentity = snapshot.trackIdentity
        autoPauseRequestID = requestID
        fetchProcessID(of: snapshot, using: bridge) { [weak self] processID in
            self?.completeAutoPauseRequest(
                requestID: requestID,
                processID: processID,
                sessionID: sessionID,
                trackIdentity: trackIdentity
            )
        }
    }

    /// The process behind `session`: its app's when the session names one, else whichever app
    /// macOS elects as now-playing, which takes a daemon round trip to learn.
    private func fetchProcessID(
        of session: NowPlaying,
        using bridge: MediaRemoteBridge,
        _ completion: @escaping @MainActor (pid_t?) -> Void
    ) {
        if let app = session.app {
            completion(app.processID)
            return
        }
        bridge.fetchNowPlayingApplicationPID(on: .main) { processID in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(processID) }
            }
        }
    }

    private func completeAutoPauseRequest(
        requestID: UUID,
        processID: pid_t?,
        sessionID: String,
        trackIdentity: String
    ) {
        guard autoPauseRequestID == requestID,
              SettingsStore.shared.callAutoPausesMusic,
              callMonitor.isCallLikely,
              let bridge,
              let snapshot = session(sessionID),
              snapshot.trackIdentity == trackIdentity,
              snapshot.isPlaying else {
            if autoPauseRequestID == requestID {
                autoPauseRequestID = nil
            }
            return
        }

        autoPauseRequestID = nil
        clearExpectedPlaying()
        guard bridge.send(.pause, to: snapshot) else { return }
        autoPauseClaim = AutoPauseClaim(
            sessionID: sessionID,
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

    private func session(_ sessionID: String) -> NowPlaying? {
        sessions.first { $0.sessionID == sessionID }
    }

    /// Keep the claim only while the session it paused reaches and remains paused on the same
    /// track. The claim follows that session, whichever one is presented.
    private func reconcileAutoPauseClaim(with sessions: [NowPlaying]) {
        guard var claim = autoPauseClaim else { return }
        guard let snapshot = sessions.first(where: { $0.sessionID == claim.sessionID }),
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
              let snapshot = session(claim.sessionID),
              snapshot.trackIdentity == claim.trackIdentity,
              !snapshot.isPlaying,
              let bridge else {
            clearAutoPauseClaim(droppedBecause: autoPauseClaimDropReason())
            return
        }

        let requestID = UUID()
        autoPauseRequestID = requestID
        fetchProcessID(of: snapshot, using: bridge) { [weak self] processID in
            self?.completeAutoResumeRequest(
                requestID: requestID,
                processID: processID,
                bridge: bridge
            )
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
              let snapshot = session(claim.sessionID),
              snapshot.trackIdentity == claim.trackIdentity,
              !snapshot.isPlaying else {
            if autoPauseRequestID == requestID {
                clearAutoPauseClaim(droppedBecause: autoPauseClaimDropReason())
            }
            return
        }

        clearAutoPauseClaim()
        if bridge.send(.play, to: snapshot) {
            AppLog.notice(.media, "auto-resume issued")
            refreshAfterTransportCommand()
        }
    }

    private func autoPauseClaimDropReason() -> AutoPauseClaimDropReason {
        if !SettingsStore.shared.callAutoPausesMusic {
            return .disabled
        }
        guard let claim = autoPauseClaim,
              let snapshot = session(claim.sessionID),
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

    /// Send a transport command to `session`, then refresh shortly after so the UI reflects the
    /// new state even before the helper reports it.
    private func sendCommand(_ command: MediaRemoteBridge.Command, to session: NowPlaying) {
        guard let bridge else { return }
        Task.detached(priority: .userInitiated) { [weak self, bridge] in
            bridge.send(command, to: session)
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

    /// Whether a play/pause can reach `session`.
    func canToggle(_ session: NowPlaying) -> Bool {
        bridge?.canSend(to: session) ?? false
    }

    /// Toggle the presented session.
    func togglePlayPause() {
        guard let nowPlaying else { return }
        togglePlayPause(sessionID: nowPlaying.sessionID)
    }

    /// Toggle one session, presented or not.
    func togglePlayPause(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        if callMonitor.isCallLikely, autoPauseClaim?.sessionID == sessionID {
            clearAutoPauseClaim(droppedBecause: .manualChange)
        }
        // Optimistically flip the play state so the button, scrubber, and selection respond
        // instantly; the post-command read reconciles with the daemon's actual state.
        var updated = sessions
        let target = !updated[index].isPlaying
        updated[index].setPlaying(target)
        setExpectedPlaying(target, for: updated[index])
        present(updated)
        sendCommand(.togglePlayPause, to: updated[index])
    }

    // Track changes invalidate any pending play/pause expectation (new track, new state).
    func nextTrack() {
        skip(.nextTrack)
    }

    func previousTrack() {
        skip(.previousTrack)
    }

    private func skip(_ command: MediaRemoteBridge.Command) {
        guard let nowPlaying else { return }
        clearExpectedPlaying()
        if autoPauseClaim?.sessionID == nowPlaying.sessionID {
            clearAutoPauseClaim(droppedBecause: .trackChange)
        }
        sendCommand(command, to: nowPlaying)
    }
}
