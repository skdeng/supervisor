import AppKit
import Foundation
import WebKit

/// A value a page's script returned, in a form that carries no reference to the page.
///
/// Everything a page returns is attacker-influenced, so a script's result is converted once,
/// at the boundary: types are checked, sizes bounded, and anything unrecognised becomes `null`.
/// The name keeps clear of JavaScriptCore's `JSValue`, which any file importing WebKit sees.
enum ScriptValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScriptValue])
    case object([String: ScriptValue])

    static let maximumDepth = 6
    static let maximumElements = 5_000
    static let maximumKeys = 200

    init(_ any: Any?, depth: Int = 0) {
        guard depth <= Self.maximumDepth, let any else {
            self = .null
            return
        }
        switch any {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // A boolean and a number share a bridged class; the type id tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.isFinite {
                self = .number(number.doubleValue)
            } else {
                self = .null
            }
        case let array as [Any]:
            self = .array(array.prefix(Self.maximumElements).map { ScriptValue($0, depth: depth + 1) })
        case let dictionary as [String: Any]:
            var object: [String: ScriptValue] = [:]
            for (key, value) in dictionary.prefix(Self.maximumKeys) {
                object[key] = ScriptValue(value, depth: depth + 1)
            }
            self = .object(object)
        default:
            self = .null
        }
    }

    var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var bool: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    /// The number as an integer, when it is one that fits.
    var int: Int? {
        guard case let .number(value) = self, let whole = Int(exactly: value) else { return nil }
        return whole
    }

    var array: [ScriptValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    subscript(key: String) -> ScriptValue? {
        if case let .object(value) = self { value[key] } else { nil }
    }
}

/// Lets one task at a time through; the rest wait their turn in order.
@MainActor
final class SerialGate {
    /// Whether a task is inside, so that a caller can tell it will have to wait.
    private(set) var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func perform<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// One web view that reads pages for a visit, kept in a window the person never sees
/// (`keepRendering` says where that window is and why).
///
/// Where it may go is decided by its `SiteNavigationPolicy`, which every main-frame navigation
/// is held to, redirects and script navigations included. It loads addresses and never clicks:
/// nothing here follows a link by activating it. New windows are refused, downloads cancelled,
/// and the dialogs a page raises are answered at once so a page cannot hold the reader.
///
/// **Where the page is.** `committedURL` and `hasOnlySecureContent` describe the page the web
/// view displays. `webView.url` names a page still loading as soon as a load starts, so it is
/// not what a person is shown as the address; `locationObserver` is called when the displayed
/// page or its secure state changes, never when a load merely starts.
///
/// **A simulated site.** With `simulatedPages` set, each main-frame navigation is answered with
/// the HTML the closure returns for that request, served at the request's own `https://` URL by
/// `loadSimulatedRequest`, so a page sees a real origin, path, and secure context while no
/// request leaves the machine. A navigation the closure answers with nil fails, and subframe
/// loads other than `about:` ones are cancelled: the seam turns the network off for the
/// browser. WebKit calls the policy delegate again for the simulated load itself, which
/// `pendingServe` recognizes; sub-resources are not intercepted, so simulated pages must be
/// self-contained.
@MainActor
final class SiteBrowser: NSObject {
    enum Failure: Error, Equatable {
        /// The address is not one the policy allows as a main-frame load.
        case notAllowed
        /// The page tried to go somewhere the policy does not allow.
        case leftSite
        case loadFailed
        case timedOut
        /// The browser was closed; nothing is loaded, read, or filled in it any more.
        case closed

        var caseName: String {
            switch self {
            case .notAllowed: "notAllowed"
            case .leftSite: "leftSite"
            case .loadFailed: "loadFailed"
            case .timedOut: "timedOut"
            case .closed: "closed"
            }
        }
    }

    /// Decides from successive looks at a page's text length when the page has held still.
    struct SettleTracker: Equatable, Sendable {
        let stablePolls: Int
        private var lastLength = -1
        private var stable = 0

        init(stablePolls: Int) {
            self.stablePolls = stablePolls
        }

        /// Takes one look at a page that has finished loading. True once the length has held
        /// for `stablePolls` looks in a row after the first.
        mutating func record(length: Int) -> Bool {
            if length == lastLength {
                stable += 1
            } else {
                stable = 0
                lastLength = length
            }
            return stable >= stablePolls
        }

        /// Takes a look that found the page still loading: the count starts over.
        mutating func reset() {
            lastLength = -1
            stable = 0
        }
    }

    /// How long the browser waits for a page to finish and settle.
    struct Settling: Sendable {
        /// The gap between two looks at a page that is settling.
        var pollInterval: Duration = .milliseconds(400)
        /// How many gaps in a row the page's text length must hold still.
        var stablePolls = 2
        /// How long to wait for a loaded page to hold still before reading it anyway.
        var settleLimit: Duration = .seconds(12)
        /// The limit on one `open`, load and settling together.
        var totalLimit: Duration = .seconds(30)
        /// How long to wait for a page to react to a submitted form or a clicked button.
        var actionGrace: Duration = .seconds(5)
        /// The limit on one script.
        var scriptTimeout: Duration = .seconds(10)

        static let standard = Settling()
    }

    /// Answers a request with a page's HTML, or nil for a request that has no page.
    typealias SimulatedPages = @MainActor (URLRequest) -> String?

    /// The identifier of the data store this feature's cookies and site data live in.
    static let storeIdentifier = UUID(uuidString: "C3A5D1E2-8B47-4F0A-9E61-52D7B4A8F319")!
    /// The persistent data store of signed-in sessions. It belongs to this feature alone.
    static let sharedStore = WKWebsiteDataStore(forIdentifier: storeIdentifier)

    private static let initialFrame = NSRect(x: 0, y: 0, width: 1024, height: 768)
    private static let maximumLinks = 2_000
    private static let maximumLoggedRefusals = 3

    let webView: WKWebView
    var policy: SiteNavigationPolicy
    /// Hosts of main-frame pages that finished loading.
    /// What follows the engine's own agent string: the tokens Safari adds, with the version of
    /// the Safari installed on this Mac. The web view runs that same WebKit, so a version from
    /// another release would describe an engine the page is not running on.
    static let agentSuffix = "Version/\(safariVersion(installed: installedSafariVersion)) Safari/605.1.15"

    private static var installedSafariVersion: String? {
        Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The installed Safari's version when it reads as one, else the system's own version,
    /// which Safari's follows.
    static func safariVersion(
        installed: String?,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        if let installed,
           installed.range(of: #"\A[0-9]{1,3}(\.[0-9]{1,3}){0,2}\z"#, options: .regularExpression) != nil {
            return installed
        }
        return "\(system.majorVersion).\(system.minorVersion)"
    }

    private(set) var visitedHosts: Set<String> = []
    /// Hosts of every main-frame navigation the policy allowed, redirect hops included.
    private(set) var traversedHosts: Set<String> = []
    /// Main-frame navigations the policy refused.
    private(set) var refusedNavigations = 0
    /// Requests to open a new window, all refused.
    private(set) var blockedWindows = 0
    /// Frames inside a page that were refused a load.
    private(set) var blockedFrames = 0
    /// The address of the page on display: set when a main-frame load commits or finishes, and
    /// kept when a load fails before committing.
    private(set) var committedURL: URL?
    /// Called on the main actor when the page on display changes, finishes loading, stays put
    /// after a load that failed, or changes whether all its content came over a secure
    /// connection.
    var locationObserver: (@MainActor () -> Void)?
    /// Called on the main actor each time the person types into a password field on the page.
    /// Only a browser whose `Observation` includes typing calls it.
    var passwordTypedObserver: (@MainActor () -> Void)?
    /// Called on the main actor each time the person types into any field on the page, a
    /// password field included. Only a browser whose `Observation` includes typing calls it.
    var typedObserver: (@MainActor () -> Void)?
    /// Called on the main actor with each user name or password typed into a field of the main
    /// frame, and each clear of such a field (`TypedCredential.Kind.cleared`). Only a browser
    /// made with `typingAndCredentials` calls it.
    var credentialObserver: (@MainActor (TypedCredential) -> Void)?
    /// Called on the main actor each time the main frame finishes a load.
    var pageFinishedObserver: (@MainActor () -> Void)?
    /// Messages from the credential script that failed `TypedCredential`'s checks. Only the
    /// count is kept.
    private(set) var droppedCredentials = 0
    /// What the page listener has reported. Only a browser made with a `PageCapture` adds to
    /// it.
    private(set) var captureLog = PageCaptureLog()

    private let window: NSWindow
    private let simulatedPages: SimulatedPages?
    private let settling: Settling
    private let gate = SerialGate()

    private var pendingServe: (url: URL, method: String)?
    private var navigationStarts = 0
    private var currentNavigation: WKNavigation?
    private var currentFinished = false
    private var loadFailures = 0
    private(set) var isClosed = false
    private var secureContentObservation: NSKeyValueObservation?
    private var closeHandlers: [UUID: @MainActor () -> Void] = [:]
    private var pendingScripts: [ObjectIdentifier: PendingScript] = [:]
    private let typingRelay: TypingRelay?
    private let credentialRelay: CredentialRelay?
    private let capture: PageCapture?
    private let captureRelay: PageCaptureRelay?

    /// The message the typing script posts. Its body is one of `TypedField`'s raw values: which
    /// kind of field took the input, never what was typed.
    nonisolated static let typingMessage = "supervisorTyping"

    /// The message the credential script posts: one report of what a person typed into a user
    /// name or password field, in the shape `TypedCredential` reads.
    nonisolated static let credentialMessage = "supervisorCredential"

    /// What the browser reports of typing into the page. Every level reports only trusted input
    /// events, so an event a script dispatches, the app's own fills among them, is never
    /// reported. A trusted event is not proof that a person typed: a page's own script can
    /// produce one through an editing command (`document.execCommand('insertText', …)`). A report
    /// is therefore bound to the page's own origin and path and vouches for nothing more.
    enum Observation: Equatable, Sendable {
        /// Nothing.
        case none
        /// That the person typed into a field, and whether it was a password field; never what
        /// was typed (see `typedObserver` and `passwordTypedObserver`).
        case typing
        /// Everything `typing` reports, and the user name or password typed into a field of the
        /// main frame (see `credentialObserver`).
        case typingAndCredentials

        fileprivate var observesTyping: Bool { self != .none }
        fileprivate var observesCredentials: Bool { self == .typingAndCredentials }
    }

    enum TypedField: String {
        case password
        case other

        /// The kind a message body names; nil for anything that is not exactly one of them.
        init?(messageBody: Any) {
            guard let text = messageBody as? String, let kind = TypedField(rawValue: text) else {
                return nil
            }
            self = kind
        }
    }

    /// With an `observation` that includes typing, a script in the app's isolated content world
    /// reports each trusted input into a field of the page (see `typedObserver` and
    /// `passwordTypedObserver`); with `typingAndCredentials`, a second script, for the main
    /// frame alone, reports a user name or password typed (see `credentialObserver`). The
    /// scripts and their message handlers live in the isolated world, which the page's own
    /// scripts cannot reach.
    ///
    /// With a `capture`, its listener is injected into the page's own world in every frame and
    /// reports into `captureLog` (see `PageCapture` for what that is worth). Every load a page
    /// in this browser sets off is held to `contentRules`.
    init(
        policy: SiteNavigationPolicy,
        dataStore: WKWebsiteDataStore = SiteBrowser.sharedStore,
        simulatedPages: SimulatedPages? = nil,
        settling: Settling = .standard,
        observation: Observation = .none,
        capture: PageCapture? = nil,
        contentRules: [WKContentRuleList] = []
    ) {
        self.policy = policy
        self.simulatedPages = simulatedPages
        self.settling = settling
        self.capture = capture

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // Sites refuse the bare WebKit agent string as an unsupported browser.
        configuration.applicationNameForUserAgent = Self.agentSuffix
        if observation.observesTyping {
            let relay = TypingRelay()
            configuration.userContentController.addUserScript(WKUserScript(
                source: Scripts.typing,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            ))
            configuration.userContentController.add(
                relay,
                contentWorld: .defaultClient,
                name: Self.typingMessage
            )
            typingRelay = relay
        } else {
            typingRelay = nil
        }
        if observation.observesCredentials {
            let relay = CredentialRelay()
            configuration.userContentController.addUserScript(WKUserScript(
                source: Scripts.credentials,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            configuration.userContentController.add(
                relay,
                contentWorld: .defaultClient,
                name: Self.credentialMessage
            )
            credentialRelay = relay
        } else {
            credentialRelay = nil
        }
        if let capture {
            let relay = PageCaptureRelay()
            configuration.userContentController.addUserScript(WKUserScript(
                source: capture.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            ))
            configuration.userContentController.add(relay, contentWorld: .page, name: PageCapture.message)
            captureRelay = relay
        } else {
            captureRelay = nil
        }
        for rules in contentRules {
            configuration.userContentController.add(rules)
        }
        webView = WKWebView(frame: Self.initialFrame, configuration: configuration)

        let container = NSView(frame: Self.initialFrame)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window = NSWindow(
            contentRect: Self.initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        let renders = Self.keepRendering(webView, in: window)

        super.init()
        rendersWhileHidden = renders
        webView.navigationDelegate = self
        webView.uiDelegate = self
        typingRelay?.browser = self
        credentialRelay?.browser = self
        captureRelay?.browser = self
        secureContentObservation = webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.locationObserver?()
            }
        }
    }

    var currentURL: URL? { webView.url }

    /// Whether pages in the hidden window render: true where `keepRendering` found WebKit's
    /// call and put the window on screen.
    private(set) var rendersWhileHidden = false

    /// Makes pages in the hidden window render as they do on screen. **A web view whose window
    /// is not on screen tells its page it is hidden and gives it no animation frames**, and a
    /// page that reveals its content on an animation frame (a streamed page swapping a loading
    /// placeholder for what arrived) then stays on the placeholder for good: the load finishes,
    /// the text length holds at zero, and the read comes back empty with nothing failing.
    /// So the window is ordered in fully transparent, beneath the desktop, passing every click
    /// through, and the web view is told to skip its test of what covers the window, which
    /// would find such a window covered. Beneath the desktop it is out of reach of Mission
    /// Control, Stage Manager, and the window pickers. That call is private to WebKit; where
    /// it is missing the window stays off screen and pages render as far as a hidden page
    /// does, which is logged once.
    private static func keepRendering(_ webView: WKWebView, in window: NSWindow) -> Bool {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else {
            if !reportedMissingOcclusionCall {
                reportedMissingOcclusionCall = true
                AppLog.error(.sites, "hidden pages will not render: occlusion call missing")
            }
            return false
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)

        window.alphaValue = 0
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        window.orderFrontRegardless()
        return true
    }

    private static var reportedMissingOcclusionCall = false

    /// A browser freed without `close()` takes its window off screen with it.
    isolated deinit {
        guard !isClosed else { return }
        webView.stopLoading()
        window.orderOut(nil)
        window.close()
    }

    /// Moves the web view out of its hidden window into `host`, filling it, for a person to
    /// watch and type into. Loading and reading go on as before; `close()` removes the view
    /// from the host.
    func present(in host: NSView) {
        guard !isClosed else { return }
        webView.removeFromSuperview()
        window.orderOut(nil)
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }

    /// Stops loading and releases the window. The browser is of no further use.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for call in Array(pendingScripts.values) { finish(call, .failure(Failure.closed)) }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllScriptMessageHandlers(from: .defaultClient)
        secureContentObservation?.invalidate()
        secureContentObservation = nil
        webView.removeFromSuperview()
        window.close()
        locationObserver = nil
        pageFinishedObserver = nil
        passwordTypedObserver = nil
        typedObserver = nil
        credentialObserver = nil
        let handlers = closeHandlers.values
        closeHandlers.removeAll()
        handlers.forEach { $0() }
    }

    /// Calls `handler` once when the browser closes, at once if it already has. The returned
    /// token withdraws it.
    @discardableResult
    func whenClosed(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        if isClosed {
            handler()
        } else {
            closeHandlers[token] = handler
        }
        return token
    }

    func withdrawCloseHandler(_ token: UUID) {
        closeHandlers.removeValue(forKey: token)
    }

    /// Reports a person's typing into a field of the page; the page script's message lands
    /// here.
    func noteTyped(into field: TypedField) {
        guard !isClosed else { return }
        if field == .password { passwordTypedObserver?() }
        typedObserver?()
    }

    /// Reports a user name or password the person typed; `credentialObserver` is called with it
    /// unless the browser is closed.
    func noteCredential(_ credential: TypedCredential) {
        guard !isClosed else { return }
        credentialObserver?(credential)
    }

    /// Takes what the credential script's message handler received, with the facts about the
    /// frame that sent it. A message that does not pass `TypedCredential`'s checks is counted in
    /// `droppedCredentials` and nothing of it is kept or logged.
    fileprivate func receiveCredentialMessage(
        _ body: Any,
        isMainFrame: Bool,
        frameScheme: String?,
        frameHost: String?,
        framePort: Int?
    ) {
        guard !isClosed else { return }
        guard let credential = TypedCredential(
            messageBody: body,
            isMainFrame: isMainFrame,
            frameScheme: frameScheme,
            frameHost: frameHost,
            framePort: framePort
        ) else {
            droppedCredentials += 1
            return
        }
        noteCredential(credential)
    }

    /// Takes one report of the page listener, with the facts about the frame that sent it.
    func receiveCapture(_ body: Any, from frame: PageCaptureLog.Frame) {
        guard !isClosed, let capture else { return }
        captureLog.record(body, from: frame, capture: capture)
    }

    private func ensureOpen() throws {
        if isClosed { throw Failure.closed }
    }

    // MARK: Reading

    /// Loads `url`, waits for the page to settle, and returns what it says.
    func open(_ url: URL) async throws -> PageSnapshot {
        try ensureOpen()
        guard policy.allowsMainFrame(url) else { throw Failure.notAllowed }
        return try await gate.perform {
            try ensureOpen()
            let marker = marker()
            let deadline = ContinuousClock.now + settling.totalLimit
            let staysInDocument = Self.isWithinCurrentDocument(url, current: webView.url)
            if !staysInDocument {
                currentNavigation = nil
                currentFinished = false
            }
            webView.load(URLRequest(url: url))
            do {
                if staysInDocument {
                    try await waitForFragmentChange(to: url, since: marker, deadline: deadline)
                }
                try await waitForLoad(since: marker, deadline: deadline)
                try await settle(since: marker, deadline: deadline)
                return try await readSnapshot()
            } catch {
                webView.stopLoading()
                throw error
            }
        }
    }

    /// What the page that is open says.
    func snapshot() async throws -> PageSnapshot {
        try ensureOpen()
        return try await gate.perform {
            try ensureOpen()
            return try await readSnapshot()
        }
    }

    /// Waits for the page that is open, which the user may have navigated, to finish loading
    /// and hold still.
    func settleLoadedPage() async throws {
        try ensureOpen()
        try await gate.perform {
            try ensureOpen()
            let marker = marker()
            try await settle(since: marker, deadline: ContinuousClock.now + settling.totalLimit)
        }
    }

    /// The state of the browser's navigations, taken before an action so that whatever the
    /// action sets off is seen by `settleAfterAction`, however quickly it happens.
    struct ActionMark {
        fileprivate let marker: Marker
    }

    func markAction() -> ActionMark {
        ActionMark(marker: marker())
    }

    /// Waits for the page to react to something done to it: a form submitted or a button
    /// clicked. When a navigation starts or the page's text changes within `actionGrace`, it
    /// waits for the page to finish and settle; otherwise it returns with the page unchanged.
    /// A navigation refused or a load failed since `mark` (by default, since this call) throws.
    func settleAfterAction(since mark: ActionMark? = nil) async throws {
        try ensureOpen()
        try await gate.perform {
            try ensureOpen()
            let marker = mark?.marker ?? marker()
            let deadline = ContinuousClock.now + settling.totalLimit
            let before = try? await signature()
            let graceEnd = ContinuousClock.now + settling.actionGrace
            let tick = min(max(settling.pollInterval / 4, .milliseconds(20)), .milliseconds(100))
            while ContinuousClock.now < graceEnd {
                try check(marker)
                if navigationStarts != marker.starts { break }
                if let now = try? await signature(), now != before { break }
                try await Task.sleep(for: tick)
            }
            try check(marker)
            do {
                if navigationStarts != marker.starts {
                    try await waitForLoad(since: marker, deadline: deadline)
                }
                try await settle(since: marker, deadline: deadline)
            } catch {
                webView.stopLoading()
                throw error
            }
        }
    }

    /// Runs `body` as an async function in the isolated content world and returns its result.
    /// Values reach the script only through `arguments`, never in `body`.
    ///
    /// A script that has not answered when the browser closes ends with `Failure.closed`, and
    /// one that has not answered within `timeout` (by default `settling.scriptTimeout`) with
    /// `Failure.timedOut`.
    func run(_ body: String, arguments: [String: Any] = [:], timeout: Duration? = nil) async throws -> ScriptValue {
        try ensureOpen()
        let limit = timeout ?? settling.scriptTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let call = PendingScript(continuation)
            pendingScripts[ObjectIdentifier(call)] = call
            webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: nil,
                in: .defaultClient
            ) { result in
                switch result {
                case let .success(value): self.finish(call, .success(ScriptValue(value)))
                case .failure: self.finish(call, .failure(Failure.loadFailed))
                }
            }
            call.timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                self.finish(call, .failure(Failure.timedOut))
            }
        }
    }

    /// How many scripts are waiting for an answer.
    var pendingScriptCount: Int { pendingScripts.count }

    /// Answers `call` once; a later answer to the same call is ignored.
    private func finish(_ call: PendingScript, _ result: Result<ScriptValue, Error>) {
        guard pendingScripts.removeValue(forKey: ObjectIdentifier(call)) != nil else { return }
        call.timer?.cancel()
        call.continuation.resume(with: result)
    }

    /// A script whose answer has not arrived, which the browser answers if it closes first.
    @MainActor
    private final class PendingScript {
        let continuation: CheckedContinuation<ScriptValue, Error>
        var timer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<ScriptValue, Error>) {
            self.continuation = continuation
        }
    }

    // MARK: Waiting

    fileprivate struct Marker {
        let starts: Int
        let refused: Int
        let failures: Int
    }

    private func marker() -> Marker {
        Marker(starts: navigationStarts, refused: refusedNavigations, failures: loadFailures)
    }

    /// Throws when, since `marker`, a navigation was refused or a load failed.
    private func check(_ marker: Marker) throws {
        if refusedNavigations != marker.refused { throw Failure.leftSite }
        if loadFailures != marker.failures { throw Failure.loadFailed }
        if isClosed { throw Failure.closed }
    }

    private var isCurrentLoadFinished: Bool { currentNavigation != nil && currentFinished }

    /// Whether a response is one the browser will not show: a type the web view cannot display,
    /// or one the server marks as an attachment to save.
    static func refusesResponse(canShowMIMEType: Bool, response: URLResponse) -> Bool {
        guard canShowMIMEType else { return true }
        let disposition = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return disposition?.hasPrefix("attachment") == true
    }

    /// Whether loading `target` only moves to a fragment of the page that is open. The web view
    /// reports no load for that, as the document stays where it is.
    static func isWithinCurrentDocument(_ target: URL, current: URL?) -> Bool {
        guard let current, target.fragment != nil else { return false }
        func withoutFragment(_ url: URL) -> String? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.fragment = nil
            return components.string
        }
        guard let targetBase = withoutFragment(target), let currentBase = withoutFragment(current) else {
            return false
        }
        return targetBase == currentBase
    }

    /// Waits until a load to a fragment of the open page has taken effect: the page's address
    /// is the new one, or a navigation has started.
    private func waitForFragmentChange(
        to target: URL,
        since marker: Marker,
        deadline: ContinuousClock.Instant
    ) async throws {
        let limit = min(deadline, ContinuousClock.now + .seconds(2))
        while navigationStarts == marker.starts, webView.url != target, ContinuousClock.now < limit {
            try check(marker)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForLoad(since marker: Marker, deadline: ContinuousClock.Instant) async throws {
        while true {
            try check(marker)
            if isCurrentLoadFinished { return }
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits until the loaded page's text length has held still for `stablePolls` gaps, or
    /// `settleLimit` has passed.
    private func settle(since marker: Marker, deadline: ContinuousClock.Instant) async throws {
        let settleEnd = ContinuousClock.now + settling.settleLimit
        var tracker = SettleTracker(stablePolls: settling.stablePolls)
        while true {
            try check(marker)
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            let startsBefore = navigationStarts
            var sample: (complete: Bool, length: Int)?
            if isCurrentLoadFinished { sample = try? await readiness() }
            if let sample, sample.complete, navigationStarts == startsBefore, isCurrentLoadFinished {
                if tracker.record(length: sample.length) { return }
            } else {
                tracker.reset()
            }
            if ContinuousClock.now >= settleEnd { return }
            try await Task.sleep(for: settling.pollInterval)
        }
    }

    /// The limit on one of the small scripts the settle loops poll with. A script sent while
    /// the document it runs in is being replaced by a navigation can go unanswered, and each
    /// poll that goes unanswered holds a settle loop for this long; its caller takes the timeout
    /// as a sample that says nothing and looks again.
    private var pollScriptTimeout: Duration { min(settling.scriptTimeout, .seconds(2)) }

    private func readiness() async throws -> (complete: Bool, length: Int)? {
        let value = try await run(Scripts.readiness, timeout: pollScriptTimeout)
        guard let state = value["ready"]?.string, let length = value["length"]?.int else { return nil }
        return (state == "complete", length)
    }

    private func signature() async throws -> String? {
        try await run(Scripts.signature, timeout: pollScriptTimeout).string
    }

    private func readSnapshot() async throws -> PageSnapshot {
        guard let url = webView.url, policy.allowsMainFrame(url) else { throw Failure.leftSite }
        let value = try await run(Scripts.snapshot)
        guard let title = value["title"]?.string,
              let text = value["text"]?.string,
              let links = value["links"]?.array
        else { throw Failure.loadFailed }

        var raw: [(text: String, href: String)] = []
        for link in links.prefix(Self.maximumLinks) {
            guard let label = link["text"]?.string, let address = link["href"]?.string else { continue }
            raw.append((label, address))
        }
        return PageSnapshot.make(
            url: url,
            rawTitle: title,
            rawText: text,
            rawLinks: raw,
            policy: policy
        )
    }

    // MARK: Scripts

    private enum Scripts {
        static let readiness = """
            return {
              ready: document.readyState,
              length: document.body ? document.body.innerText.length : 0
            };
            """

        static let signature = """
            return location.href + '|' + (document.body ? document.body.innerText.length : 0)
              + '|' + document.querySelectorAll('input').length;
            """

        static let snapshot = """
            const cut = (value, limit) => (typeof value === 'string' ? value.slice(0, limit) : '');
            const address = (anchor) => {
              if (typeof anchor.href === 'string') return anchor.href;
              try {
                return new URL(anchor.getAttribute('href'), document.baseURI).href;
              } catch (error) {
                return '';
              }
            };
            const links = [];
            const anchors = document.querySelectorAll('a[href]');
            for (let index = 0; index < anchors.length && links.length < 2000; index++) {
              const anchor = anchors[index];
              const label = anchor.innerText || anchor.getAttribute('aria-label') || anchor.getAttribute('title') || '';
              links.push({ text: cut(label, 300), href: cut(address(anchor), 2048) });
            }
            return {
              title: cut(document.title, 1000),
              text: document.body ? cut(document.body.innerText, 500000) : '',
              links: links
            };
            """

        /// Runs in the isolated content world, where the page's scripts cannot reach the
        /// listener or the message handler. Only a trusted input event is reported (see
        /// `Observation` for what that does not prove), and the message names the kind of field,
        /// never what was typed.
        static let typing = """
            document.addEventListener('input', (event) => {
              if (!event.isTrusted) return;
              const target = event.composedPath()[0];
              if (!(target instanceof HTMLInputElement)) return;
              const kind = target.type === 'password'
                ? '\(SiteBrowser.TypedField.password.rawValue)'
                : '\(SiteBrowser.TypedField.other.rawValue)';
              window.webkit.messageHandlers.\(SiteBrowser.typingMessage).postMessage(kind);
            }, true);
            """

        /// The field rules and the report builder of the credential script: no listener, and no
        /// effect beyond its definitions and a watch on `type` attributes.
        ///
        /// A field is a password when it is, or has been, a `password` input: the watch records
        /// every input whose `type` attribute changes away from `password`, so one a show-password
        /// toggle turns into a text input still counts, unless `SignInRules.isMaskedNonPassword`
        /// sets it apart as a masked code, PIN, or answer, which is never reported. Any other
        /// field is a user name when `SignInRules.showsUserNameField` would call it one. A code
        /// field is never reported, and neither is a field that carries a password token or word,
        /// whatever else its name says. Attributes are cut at 200 characters, past the length
        /// `TypedCredential` accepts for a field key, so a cut attribute is refused there.
        ///
        /// `credentialMessage(element)` returns the report for one input: a clear, carrying no
        /// value, when the field is empty; null when the field is not one to report or holds more
        /// than 16,384 characters.
        static let credentialHelpers = #"""
            const getAttribute = Element.prototype.getAttribute;
            const attribute = (element, name) => getAttribute.call(element, name) || '';
            const getter = (prototype, name) => Object.getOwnPropertyDescriptor(prototype, name).get;
            const readValue = getter(HTMLInputElement.prototype, 'value');
            const readType = getter(HTMLInputElement.prototype, 'type');
            const readForm = getter(HTMLInputElement.prototype, 'form');
            const readDocumentURL = getter(Document.prototype, 'URL');
            const readBaseURI = getter(Node.prototype, 'baseURI');
            const allInputs = () => Document.prototype.querySelectorAll.call(document, 'input');

            const usernamePattern = new RegExp('\#(SignInRules.usernamePattern)', 'i');
            const codeWords = \#(javaScriptList(SignInRules.codeWords));
            const notCodeWords = \#(javaScriptList(SignInRules.notCodeWords));
            const notPasswordWords = \#(javaScriptList(SignInRules.notPasswordWords));
            const passwordWords = ['password', 'passwd', 'pwd'];
            const textTypes = ['', 'text', 'email', 'tel'];
            const maximumValueLength = 16384;
            const maximumPasswordFields = \#(TypedCredential.maximumPasswordFields);

            const cut = (text) => text.slice(0, 200);
            const isLetterOrNumber = (character) => /^[\p{L}\p{N}]$/u.test(character);
            const isNumber = (character) => /^\p{N}$/u.test(character);
            const wordsOf = (text, splittingDigits) => {
              const words = [];
              let current = '';
              let previous = null;
              for (const character of text) {
                if (!isLetterOrNumber(character)) {
                  if (current !== '') words.push(current);
                  current = '';
                  previous = null;
                  continue;
                }
                if (previous !== null && current !== '') {
                  const camelBoundary = /^\p{Ll}$/u.test(previous) && /^\p{Lu}$/u.test(character);
                  const digitBoundary = splittingDigits && isNumber(previous) !== isNumber(character);
                  if (camelBoundary || digitBoundary) {
                    words.push(current);
                    current = '';
                  }
                }
                current += character;
                previous = character;
              }
              if (current !== '') words.push(current);
              return words.map((word) => word.toLowerCase());
            };

            const knownPasswordInputs = new WeakSet();
            const isPasswordInput = (element) => {
              if (readType.call(element) === 'password') {
                knownPasswordInputs.add(element);
                return true;
              }
              return knownPasswordInputs.has(element);
            };
            new MutationObserver((records) => {
              for (const record of records) {
                if (record.target instanceof HTMLInputElement
                  && (record.oldValue || '').toLowerCase() === 'password') knownPasswordInputs.add(record.target);
              }
            }).observe(document, { subtree: true, attributes: true, attributeFilter: ['type'], attributeOldValue: true });

            const factsOf = (element) => {
              const maxLength = parseInt(attribute(element, 'maxlength'), 10);
              return {
                name: cut(attribute(element, 'name')),
                id: cut(attribute(element, 'id')),
                autocomplete: cut(attribute(element, 'autocomplete').toLowerCase()),
                type: cut(attribute(element, 'type').toLowerCase()),
                inputMode: cut(attribute(element, 'inputmode').toLowerCase()),
                maxLength: Number.isFinite(maxLength) && maxLength >= 0 ? maxLength : null
              };
            };
            const tokensOf = (autocomplete) => autocomplete.split(/\s+/);
            const looksLikeUsername = (facts) => ['username', 'email'].includes(facts.autocomplete)
              || facts.type === 'email' || usernamePattern.test(facts.name) || usernamePattern.test(facts.id);
            const isCodeField = (facts) => {
              if (facts.type === 'password') return false;
              if (facts.autocomplete === 'one-time-code') return true;
              const words = [facts.name, facts.id].flatMap((text) => wordsOf(text, true).concat(wordsOf(text, false)));
              if (words.some((word) => notCodeWords.includes(word))) return false;
              if (words.some((word) => codeWords.includes(word))) return true;
              return facts.inputMode === 'numeric' && facts.maxLength !== null
                && facts.maxLength >= 4 && facts.maxLength <= 8;
            };
            const looksLikePassword = (facts) => {
              const tokens = tokensOf(facts.autocomplete);
              return tokens.includes('current-password') || tokens.includes('new-password')
                || [facts.name, facts.id].some((text) => wordsOf(text, true).some((word) => passwordWords.includes(word)));
            };
            const isMaskedNonPassword = (facts) => {
              const words = [facts.name, facts.id].flatMap((text) => wordsOf(text, true).concat(wordsOf(text, false)));
              if (words.some((word) => notCodeWords.includes(word))) return false;
              return words.some((word) => codeWords.includes(word) || notPasswordWords.includes(word));
            };
            const kindOf = (element, facts) => {
              if (tokensOf(facts.autocomplete).includes('one-time-code')) return null;
              if (isPasswordInput(element)) return isMaskedNonPassword(facts) ? null : 'password';
              if (!textTypes.includes(facts.type) || isCodeField(facts) || looksLikePassword(facts)) return null;
              return looksLikeUsername(facts) ? 'username' : null;
            };

            const hasNewPasswordToken = (element) =>
              tokensOf(attribute(element, 'autocomplete').toLowerCase()).includes('new-password');
            const actionHostOf = (element) => {
              const form = readForm.call(element);
              if (!form) return '';
              try {
                const raw = attribute(form, 'action');
                const url = new URL(raw === '' ? readDocumentURL.call(document) : raw, readBaseURI.call(document));
                return url.protocol === 'https:' ? url.hostname.toLowerCase() : '';
              } catch (error) {
                return '';
              }
            };

            const credentialMessage = (target) => {
              const facts = factsOf(target);
              const kind = kindOf(target, facts);
              if (kind === null) return null;
              const value = readValue.call(target);
              if (value.length > maximumValueLength) return null;
              if (value.length === 0) {
                return {
                  kind: 'clear',
                  name: facts.name,
                  id: facts.id,
                  autocomplete: facts.autocomplete.trim(),
                  type: kind === 'password' ? 'password' : facts.type,
                  origin: location.origin,
                  path: location.pathname
                };
              }
              const passwords = Array.prototype.filter.call(allInputs(), isPasswordInput);
              return {
                kind: kind,
                value: value,
                name: facts.name,
                id: facts.id,
                autocomplete: facts.autocomplete.trim(),
                type: kind === 'password' ? 'password' : facts.type,
                origin: location.origin,
                path: location.pathname,
                actionHost: actionHostOf(target),
                passwordFields: Math.min(passwords.length, maximumPasswordFields),
                newPassword: hasNewPasswordToken(target) || passwords.some(hasNewPasswordToken)
              };
            };
            """#

        /// Runs in the isolated content world, in the main frame only, where the page's scripts
        /// cannot reach the listener or the message handler. Only a trusted input event is
        /// reported, and a page's own script can produce one through an editing command, so a
        /// report is bound to the page's own origin and path and says nothing more about who
        /// typed. A report is also made only while the page holds transient user activation
        /// (`navigator.userActivation.isActive`, where the browser has it): that excludes an
        /// editing command a page runs as it loads or from a timer with no person acting, and
        /// does not exclude one it runs in the seconds after a click or key press. The path is
        /// the page's own `location.pathname`: the frame's request address goes stale when the
        /// page changes its address by script.
        static let credentials = #"""
            (() => {
            \#(credentialHelpers)
            const activation = navigator.userActivation;
            document.addEventListener('input', (event) => {
              if (!event.isTrusted) return;
              if (activation && !activation.isActive) return;
              const target = event.composedPath()[0];
              if (!(target instanceof HTMLInputElement)) return;
              const message = credentialMessage(target);
              if (message === null) return;
              window.webkit.messageHandlers.\#(SiteBrowser.credentialMessage).postMessage(message);
            }, true);
            })();
            """#

        /// A script array literal of `words`, which are lowercase letters and digits.
        private static func javaScriptList(_ words: Set<String>) -> String {
            "[" + words.sorted().map { "'\($0)'" }.joined(separator: ", ") + "]"
        }
    }

    /// The text of the field rules and report builder the credential script is built from, for
    /// a test to run against a page.
    static var credentialHelpersScript: String { Scripts.credentialHelpers }
}

/// Receives the credential script's message for a browser, holding it weakly: the web view's
/// content controller keeps its handlers alive for as long as the web view lives. The frame the
/// message came from is read here, from the web view, and never from the message.
@MainActor
private final class CredentialRelay: NSObject, WKScriptMessageHandler {
    weak var browser: SiteBrowser?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let frame = message.frameInfo
        browser?.receiveCredentialMessage(
            message.body,
            isMainFrame: frame.isMainFrame,
            frameScheme: frame.securityOrigin.protocol,
            frameHost: frame.securityOrigin.host,
            framePort: frame.securityOrigin.port
        )
    }
}

/// Receives the typing script's message for a browser, holding it weakly: the web view's
/// content controller keeps its handlers alive for as long as the web view lives.
@MainActor
private final class TypingRelay: NSObject, WKScriptMessageHandler {
    weak var browser: SiteBrowser?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let field = SiteBrowser.TypedField(messageBody: message.body) else { return }
        browser?.noteTyped(into: field)
    }
}

// MARK: - Navigation

extension SiteBrowser: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            return
        }
        // A navigation with no target frame is a request for a new window.
        guard let target = navigationAction.targetFrame else {
            blockedWindows += 1
            decisionHandler(.cancel)
            return
        }
        guard target.isMainFrame else {
            let allowed = policy.allowsSubframe(url)
                && (simulatedPages == nil || url.scheme?.lowercased() == "about")
            if !allowed { blockedFrames += 1 }
            decisionHandler(allowed ? .allow : .cancel)
            return
        }

        let method = navigationAction.request.httpMethod ?? "GET"
        if let served = pendingServe, served.url == url, served.method == method {
            pendingServe = nil
            decisionHandler(.allow)
            return
        }
        guard policy.allowsMainFrame(url) else {
            refusedNavigations += 1
            if refusedNavigations <= Self.maximumLoggedRefusals {
                AppLog.notice(
                    .sites,
                    "browser refused a navigation to host \(url.host(percentEncoded: true) ?? "none")"
                )
            }
            decisionHandler(.cancel)
            return
        }
        if let host = url.host(percentEncoded: false)?.lowercased() {
            traversedHosts.insert(host)
        }

        guard let simulatedPages else {
            decisionHandler(.allow)
            return
        }
        guard let html = simulatedPages(navigationAction.request) else {
            loadFailures += 1
            decisionHandler(.cancel)
            return
        }
        pendingServe = (url, method)
        decisionHandler(.cancel)
        webView.loadSimulatedRequest(navigationAction.request, responseHTML: html)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard !Self.refusesResponse(
            canShowMIMEType: navigationResponse.canShowMIMEType,
            response: navigationResponse.response
        ) else {
            if navigationResponse.isForMainFrame { loadFailures += 1 }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.cancel { _ in }
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStarts += 1
        currentNavigation = navigation
        currentFinished = false
        pendingServe = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedURL = webView.url
        locationObserver?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingServe = nil
        if navigation === currentNavigation { currentFinished = true }
        if let url = webView.url, url.scheme?.lowercased() == "https",
           let host = url.host(percentEncoded: false)?.lowercased() {
            visitedHosts.insert(host)
        }
        committedURL = webView.url
        locationObserver?()
        pageFinishedObserver?()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        noteFailure(of: navigation, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        noteFailure(of: navigation, error)
        // The page on display is the one committed before this load began.
        locationObserver?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadFailures += 1
    }

    /// Server trust is evaluated by the system; any other credential request is declined, so a
    /// page can never raise a sign-in prompt.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// A navigation the web view cancelled itself because another began is no failure.
    private func noteFailure(of navigation: WKNavigation?, _ error: any Error) {
        pendingServe = nil
        let nsError = error as NSError
        let isCancellation = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        guard !isCancellation, navigation === currentNavigation else { return }
        loadFailures += 1
        currentFinished = true
    }
}

// MARK: - Dialogs and windows

extension SiteBrowser: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        blockedWindows += 1
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}
