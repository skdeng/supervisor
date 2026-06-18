import Combine
import SwiftUI

/// DynaMusic — the system-wide now-playing module.
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
    let displayName = "DynaMusic"
    let order = 10

    /// The current now-playing snapshot, or `nil` when nothing is loaded. Drives all UI.
    @Published private(set) var nowPlaying: NowPlaying?

    /// Whether transport commands are available (MediaRemote `SendCommand` resolved).
    @Published private(set) var canControl = false

    private var context: NotchContext?
    private let bridge: MediaRemoteBridge?
    /// Reads now-playing info through the entitled helper; safe to use off the main actor.
    nonisolated let reader = NowPlayingReader()

    private var notificationObservers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    /// Guards against overlapping helper reads piling up under a burst of notifications.
    private var isReading = false

    /// Last artwork bytes seen, keyed by track identity. MediaRemote transiently drops the
    /// artwork from a poll (e.g. while scrubbing) even though the track is unchanged; we
    /// re-inject the cached bytes so the UI artwork never flickers off mid-track.
    private var cachedArtwork: (identity: String, data: Data)?

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
                    self?.refresh()
                }
                notificationObservers.append(observer)
            }
        }

        // Steady poll as a freshness fallback (elapsed position, sources that don't notify).
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
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
        guard !isReading else { return }
        isReading = true
        Task.detached(priority: .utility) { [weak self, reader] in
            let snapshot = reader.read()
            await self?.finishRead(snapshot)
        }
    }

    private func finishRead(_ snapshot: NowPlaying?) {
        isReading = false
        nowPlaying = snapshot.map(reconcileArtwork)
        reconcileCompactVisibility()
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

    func togglePlayPause() { sendCommand(.togglePlayPause) }
    func nextTrack() { sendCommand(.nextTrack) }
    func previousTrack() { sendCommand(.previousTrack) }
}
