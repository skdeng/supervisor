import Foundation

/// Runtime bridge to the private `MediaRemote` framework, resolved with `dlopen`/`dlsym`
/// so no bridging header or custom module map is required (both break SPM builds).
///
/// The framework exposes the system-wide "now playing" session: whatever app currently
/// owns media playback (Music, Spotify, Safari, podcasts, etc.). We read its info dict,
/// subscribe to change notifications, and send transport commands through it.
///
/// All symbols are unsupported/private and can change between OS releases, so every
/// `dlopen`/`dlsym` is guarded and the bridge degrades to a no-op when a symbol is
/// missing on a given system.
///
/// `@unchecked Sendable`: the bridge holds only immutable C function pointers and an
/// opaque framework handle after init. The underlying MediaRemote calls are thread-safe
/// (each takes the dispatch queue it should call back on), so the bridge can be shared
/// across the module's main actor and its background work queue.
final class MediaRemoteBridge: @unchecked Sendable {

    // MARK: C function types

    /// `MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t, void(^)(CFDictionaryRef))`.
    /// The completion is an Objective-C **block** (`void(^)(…)`), so it must be a
    /// `@convention(block)` closure — a `@convention(c)` closure parameter would be passed
    /// as a bare C function pointer where MediaRemote expects a block object, crashing when
    /// it invokes it. The block receives a toll-free-bridged `CFDictionary`/`NSDictionary`,
    /// taken as `[String: Any]`.
    private typealias GetNowPlayingInfoFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) ([String: Any]) -> Void
    ) -> Void

    /// `MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t)`.
    private typealias RegisterForNotificationsFn = @convention(c) (DispatchQueue) -> Void

    /// `MRMediaRemoteUnregisterForNowPlayingNotifications(void)`.
    private typealias UnregisterForNotificationsFn = @convention(c) () -> Void

    /// `MRMediaRemoteSendCommand(MRMediaRemoteCommand, CFDictionaryRef) -> Bool`.
    private typealias SendCommandFn = @convention(c) (Int, [String: Any]?) -> Bool

    /// `MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t, void(^)(Bool))`.
    /// The completion is an Objective-C block, hence `@convention(block)` (see above).
    private typealias GetIsPlayingFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    /// `MRMediaRemoteGetNowPlayingApplicationPID(dispatch_queue_t, void(^)(pid_t))`.
    private typealias GetApplicationPIDFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (pid_t) -> Void
    ) -> Void

    // MARK: Command codes (MRMediaRemoteCommand)

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    // MARK: Info-dict keys (kMRMediaRemoteNowPlayingInfo*)

    enum InfoKey {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let artworkIdentifier = "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
    }

    // MARK: Notification names posted by MediaRemote

    enum NotificationName {
        static let infoDidChange = "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
        static let isPlayingDidChange = "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        static let nowPlayingAppDidChange = "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
    }

    // MARK: Resolved symbols

    private let handle: UnsafeMutableRawPointer
    private let getNowPlayingInfo: GetNowPlayingInfoFn
    private let registerForNotifications: RegisterForNotificationsFn
    private let unregisterForNotifications: UnregisterForNotificationsFn?
    private let sendCommand: SendCommandFn?
    private let getIsPlaying: GetIsPlayingFn?
    private let getApplicationPID: GetApplicationPIDFn?

    /// Whether the minimum viable surface (read info) is available.
    var canSendCommands: Bool { sendCommand != nil }

    /// Fails to initialize when the framework or its essential symbols can't be resolved,
    /// so the module can degrade gracefully.
    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        ) else {
            return nil
        }
        self.handle = handle

        func resolve(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(handle, name)
        }

        guard
            let getInfoSym = resolve("MRMediaRemoteGetNowPlayingInfo"),
            let registerSym = resolve("MRMediaRemoteRegisterForNowPlayingNotifications")
        else {
            dlclose(handle)
            return nil
        }

        self.getNowPlayingInfo = unsafeBitCast(getInfoSym, to: GetNowPlayingInfoFn.self)
        self.registerForNotifications = unsafeBitCast(registerSym, to: RegisterForNotificationsFn.self)

        self.unregisterForNotifications = resolve("MRMediaRemoteUnregisterForNowPlayingNotifications")
            .map { unsafeBitCast($0, to: UnregisterForNotificationsFn.self) }
        self.sendCommand = resolve("MRMediaRemoteSendCommand")
            .map { unsafeBitCast($0, to: SendCommandFn.self) }
        self.getIsPlaying = resolve("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
            .map { unsafeBitCast($0, to: GetIsPlayingFn.self) }
        self.getApplicationPID = resolve("MRMediaRemoteGetNowPlayingApplicationPID")
            .map { unsafeBitCast($0, to: GetApplicationPIDFn.self) }
    }

    deinit {
        // Note: do not dlclose() while observers may still fire; the bridge lifetime is
        // tied to the module which unregisters in deactivate() before release.
        dlclose(handle)
    }

    // MARK: Reads

    /// Fetch the current now-playing info dict, delivered on `queue`.
    func fetchNowPlayingInfo(on queue: DispatchQueue, _ completion: @escaping @Sendable ([String: Any]) -> Void) {
        getNowPlayingInfo(queue, completion)
    }

    /// Fetch whether the now-playing app is currently playing, delivered on `queue`.
    /// No-op (delivers `false`) when the symbol is unavailable.
    func fetchIsPlaying(on queue: DispatchQueue, _ completion: @escaping @Sendable (Bool) -> Void) {
        guard let getIsPlaying else {
            queue.async { completion(false) }
            return
        }
        getIsPlaying(queue, completion)
    }

    /// Fetch the process that owns the current now-playing session. A missing symbol or invalid
    /// process id is delivered as `nil`.
    func fetchNowPlayingApplicationPID(
        on queue: DispatchQueue,
        _ completion: @escaping @Sendable (pid_t?) -> Void
    ) {
        guard let getApplicationPID else {
            queue.async { completion(nil) }
            return
        }
        getApplicationPID(queue) { processID in
            completion(processID > 0 ? processID : nil)
        }
    }

    // MARK: Notifications

    /// Ask MediaRemote to begin posting now-playing notifications on `queue`. Required
    /// before the `NotificationName.*` notifications fire on `NotificationCenter.default`.
    func registerForNotifications(on queue: DispatchQueue) {
        registerForNotifications(queue)
    }

    /// Stop MediaRemote notifications.
    func unregister() {
        unregisterForNotifications?()
    }

    // MARK: Commands

    /// Send a transport command to the now-playing app. Returns `false` when the command
    /// symbol is unavailable or the command was not accepted.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let sendCommand else { return false }
        return sendCommand(command.rawValue, nil)
    }
}
