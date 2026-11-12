import Foundation

/// Runtime bridge to the private `MediaRemote` framework, resolved with `dlopen`/`dlsym`
/// so no bridging header or custom module map is required (both break SPM builds).
///
/// Carries what this app's own process is admitted to do with now-playing sessions: subscribe
/// to change notifications and send transport commands, either to the app macOS elects as
/// now-playing or to one specific app's session. Info reads are gated to Apple-signed hosts and
/// go through the entitled helper instead (`NowPlayingStream`, `NowPlayingReader`).
///
/// All symbols are unsupported/private and can change between OS releases, so every
/// `dlopen`/`dlsym` is guarded and the bridge degrades to a no-op when a symbol is
/// missing on a given system.
///
/// `@unchecked Sendable`: the bridge holds only immutable C function pointers, class
/// references, and an opaque framework handle after init. The underlying MediaRemote calls are
/// thread-safe (each takes the dispatch queue it should call back on), so the bridge can be
/// shared across the module's main actor and its background work queue.
final class MediaRemoteBridge: @unchecked Sendable {

    // MARK: C function types

    /// `MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t)`.
    private typealias RegisterForNotificationsFn = @convention(c) (DispatchQueue) -> Void

    /// `MRMediaRemoteUnregisterForNowPlayingNotifications(void)`.
    private typealias UnregisterForNotificationsFn = @convention(c) () -> Void

    /// `MRMediaRemoteSendCommand(MRMediaRemoteCommand, CFDictionaryRef) -> Bool`.
    private typealias SendCommandFn = @convention(c) (Int, [String: Any]?) -> Bool

    /// `MRMediaRemoteGetNowPlayingApplicationPID(dispatch_queue_t, void(^)(pid_t))`.
    /// The completion is an Objective-C **block** (`void(^)(…)`), so it must be a
    /// `@convention(block)` closure — a `@convention(c)` closure parameter would be passed
    /// as a bare C function pointer where MediaRemote expects a block object, crashing when
    /// it invokes it.
    private typealias GetApplicationPIDFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (pid_t) -> Void
    ) -> Void

    // MARK: Objective-C method types (per-app commands)
    //
    // The per-app surface is Objective-C classes, reached through each method's implementation
    // pointer cast to its exact C signature. An initializer consumes the receiver it is handed
    // and returns a +1 object, so both travel as raw pointers whose ownership is transferred
    // explicitly; every other object argument is borrowed.

    /// `-[MRClient initWithProcessIdentifier:bundleIdentifier:]`.
    private typealias InitClientFn = @convention(c) (
        UnsafeMutableRawPointer, Selector, Int32, NSString
    ) -> UnsafeMutableRawPointer?

    /// `-[MRPlayerPath initWithOrigin:client:player:]`.
    private typealias InitPlayerPathFn = @convention(c) (
        UnsafeMutableRawPointer, Selector, AnyObject, AnyObject, AnyObject?
    ) -> UnsafeMutableRawPointer?

    /// `-[MRNowPlayingRequest initWithPlayerPath:]`.
    private typealias InitRequestFn = @convention(c) (
        UnsafeMutableRawPointer, Selector, AnyObject
    ) -> UnsafeMutableRawPointer?

    /// `-[MRNowPlayingRequest sendCommand:options:queue:completion:]`. The completion block
    /// receives an `MRCommandResult`.
    private typealias SendRequestCommandFn = @convention(c) (
        AnyObject, Selector, UInt32, NSDictionary?, DispatchQueue,
        @escaping @convention(block) (AnyObject?) -> Void
    ) -> Void

    /// The classes and method implementations a per-app command needs, resolved together so the
    /// surface is either wholly usable or absent.
    struct AppCommandSurface {
        private let origin: AnyObject
        private let clientClass: AnyObject
        private let playerPathClass: AnyObject
        private let requestClass: AnyObject
        private let initClient: InitClientFn
        private let initPlayerPath: InitPlayerPathFn
        private let initRequest: InitRequestFn
        private let sendCommand: SendRequestCommandFn

        private static let initClientSelector = NSSelectorFromString("initWithProcessIdentifier:bundleIdentifier:")
        private static let initPlayerPathSelector = NSSelectorFromString("initWithOrigin:client:player:")
        private static let initRequestSelector = NSSelectorFromString("initWithPlayerPath:")
        private static let sendCommandSelector = NSSelectorFromString("sendCommand:options:queue:completion:")

        init?() {
            guard
                let originClass = NSClassFromString("MROrigin"),
                let clientClass = NSClassFromString("MRClient"),
                let playerPathClass = NSClassFromString("MRPlayerPath"),
                let requestClass = NSClassFromString("MRNowPlayingRequest"),
                let localOrigin = class_getClassMethod(originClass, NSSelectorFromString("localOrigin")),
                let initClient = class_getInstanceMethod(clientClass, Self.initClientSelector),
                let initPlayerPath = class_getInstanceMethod(playerPathClass, Self.initPlayerPathSelector),
                let initRequest = class_getInstanceMethod(requestClass, Self.initRequestSelector),
                let sendCommand = class_getInstanceMethod(requestClass, Self.sendCommandSelector)
            else {
                return nil
            }

            typealias LocalOriginFn = @convention(c) (AnyObject, Selector) -> AnyObject?
            let fetchOrigin = unsafeBitCast(method_getImplementation(localOrigin), to: LocalOriginFn.self)
            guard let origin = fetchOrigin(originClass, NSSelectorFromString("localOrigin")) else {
                return nil
            }

            self.origin = origin
            self.clientClass = clientClass
            self.playerPathClass = playerPathClass
            self.requestClass = requestClass
            self.initClient = unsafeBitCast(method_getImplementation(initClient), to: InitClientFn.self)
            self.initPlayerPath = unsafeBitCast(
                method_getImplementation(initPlayerPath), to: InitPlayerPathFn.self)
            self.initRequest = unsafeBitCast(method_getImplementation(initRequest), to: InitRequestFn.self)
            self.sendCommand = unsafeBitCast(
                method_getImplementation(sendCommand), to: SendRequestCommandFn.self)
        }

        /// A +1 uninitialized instance of `cls`, handed to an initializer that consumes it.
        private static func allocate(_ cls: AnyObject) -> UnsafeMutableRawPointer? {
            cls.perform(NSSelectorFromString("alloc"))?.toOpaque()
        }

        private static func adopt(_ pointer: UnsafeMutableRawPointer?) -> AnyObject? {
            pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
        }

        /// A request addressed to `app`'s own now-playing player.
        func makeRequest(for app: NowPlayingApp) -> AnyObject? {
            guard
                let rawClient = Self.allocate(clientClass),
                let client = Self.adopt(initClient(
                    rawClient, Self.initClientSelector, app.processID,
                    app.bundleIdentifier as NSString)),
                let rawPath = Self.allocate(playerPathClass),
                // A nil player addresses the client's own now-playing player.
                let path = Self.adopt(initPlayerPath(
                    rawPath, Self.initPlayerPathSelector, origin, client, nil)),
                let rawRequest = Self.allocate(requestClass)
            else {
                return nil
            }
            return Self.adopt(initRequest(rawRequest, Self.initRequestSelector, path))
        }

        /// Dispatch `command` to `app`'s session. Returns `false` when no request could be built.
        /// A command the daemon refuses is logged by its error code.
        func send(_ command: Command, to app: NowPlayingApp) -> Bool {
            guard let request = makeRequest(for: app) else { return false }
            sendCommand(
                request, Self.sendCommandSelector, UInt32(command.rawValue), nil,
                DispatchQueue.global(qos: .userInitiated)
            ) { result in
                let sendError = NSSelectorFromString("sendError")
                guard let result = result as? NSObject, result.responds(to: sendError),
                      let code = result.value(forKey: "sendError") as? Int, code != 0 else {
                    return
                }
                AppLog.error(.media, "app command \(command.rawValue) refused: send error \(code)")
            }
            return true
        }
    }

    // MARK: Command codes (MRMediaRemoteCommand)

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    // MARK: Notification names posted by MediaRemote

    enum NotificationName {
        static let infoDidChange = "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
        static let isPlayingDidChange = "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        static let nowPlayingAppDidChange = "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
    }

    // MARK: Resolved symbols

    private let handle: UnsafeMutableRawPointer
    private let registerForNotifications: RegisterForNotificationsFn
    private let unregisterForNotifications: UnregisterForNotificationsFn?
    private let sendCommand: SendCommandFn?
    private let getApplicationPID: GetApplicationPIDFn?
    private let appCommands: AppCommandSurface?

    /// Whether transport commands can be sent to the app macOS elects as now-playing.
    var canSendCommands: Bool { sendCommand != nil }
    /// Whether transport commands can be addressed to one specific app's session.
    var canSendAppCommands: Bool { appCommands != nil }

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

        guard let registerSym = resolve("MRMediaRemoteRegisterForNowPlayingNotifications") else {
            dlclose(handle)
            return nil
        }

        self.registerForNotifications = unsafeBitCast(registerSym, to: RegisterForNotificationsFn.self)

        self.unregisterForNotifications = resolve("MRMediaRemoteUnregisterForNowPlayingNotifications")
            .map { unsafeBitCast($0, to: UnregisterForNotificationsFn.self) }
        self.sendCommand = resolve("MRMediaRemoteSendCommand")
            .map { unsafeBitCast($0, to: SendCommandFn.self) }
        self.getApplicationPID = resolve("MRMediaRemoteGetNowPlayingApplicationPID")
            .map { unsafeBitCast($0, to: GetApplicationPIDFn.self) }
        self.appCommands = AppCommandSurface()
    }

    deinit {
        // Note: do not dlclose() while observers may still fire; the bridge lifetime is
        // tied to the module which unregisters in deactivate() before release.
        dlclose(handle)
    }

    // MARK: Reads

    /// Fetch the process of the app macOS elects as now-playing. A missing symbol or invalid
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

    /// Send a transport command to `session`. It is addressed to the session's own app when the
    /// per-app surface is available; a session macOS elects as now-playing, or one that carries
    /// no app identity, is otherwise reached through the elected-app command. Returns `false`
    /// when the command could not be issued. A command addressed to an app is delivered
    /// asynchronously; `true` then means it was dispatched.
    @discardableResult
    func send(_ command: Command, to session: NowPlaying) -> Bool {
        if let app = session.app, let appCommands {
            return appCommands.send(command, to: app)
        }
        guard session.app == nil || session.isElected, let sendCommand else { return false }
        return sendCommand(command.rawValue, nil)
    }

    /// Whether `send(_:to:)` has a route to `session`.
    func canSend(to session: NowPlaying) -> Bool {
        if session.app != nil, canSendAppCommands { return true }
        return (session.app == nil || session.isElected) && canSendCommands
    }
}
