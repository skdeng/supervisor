import Combine
import Foundation
import WebKit

/// The app's owner of one direct-message source: whether it is switched on, whether the person
/// is signed in to it, the syncs that copy its recent chats, and the snapshot they leave.
///
/// The snapshot sits beside the agent's working directory and never inside it: every kind of
/// run can read that directory with its file tools, and other people's messages go only to
/// the passes a tool hands them to.
@MainActor
final class DirectMessageCenter: ObservableObject {
    static let shared: DirectMessageCenter = {
        let source = DirectMessageSource.instagram
        let dataStore = WKWebsiteDataStore(forIdentifier: source.storeIdentifier)
        return DirectMessageCenter(
            source: source,
            settings: .shared,
            store: DirectMessageStore(directory: ProVisorHome.directMessagesURL),
            defaults: .standard,
            dataStore: dataStore,
            runner: standardRunner(dataStore: dataStore)
        )
    }()

    enum Status: Equatable {
        case off
        case notSignedIn
        /// The source asked for a sign-in the last time its inbox was loaded.
        case needsYou
        case signedIn(lastSync: Date?, chats: Int)
    }

    /// Why a sync was not started.
    enum Refusal: Equatable {
        case off
        case notSignedIn
        case needsYou
        /// The person is signing in, and a second browser on the session would race them.
        case signingIn
        case alreadySyncing
    }

    /// What became of a sync, in the app's words. Nothing here quotes a page.
    enum Problem: Equatable {
        case pageUnavailable
        case nothingCaptured
        case limitsUnavailable
        case notSaved

        func sentence(sourceName: String) -> String {
            switch self {
            case .pageUnavailable:
                "\(sourceName)'s inbox couldn't be loaded."
            case .nothingCaptured:
                "\(sourceName)'s inbox loaded, but no chats could be read from it."
            case .limitsUnavailable:
                "SuperVisor couldn't put its limits on the page, so the inbox wasn't loaded."
            case .notSaved:
                "The chats were read but couldn't be saved."
            }
        }
    }

    /// Runs one sync of a source; nil when the page's limits could not be set up, in which
    /// case nothing was loaded.
    typealias Runner = @MainActor (DirectMessageSource) async -> DirectMessageSync.Result?

    /// What is remembered about the person's sign-in between launches.
    struct SignInState: Equatable {
        var signedIn: Date?
        var needsPerson = false
    }

    let source: DirectMessageSource
    let dataStore: WKWebsiteDataStore

    @Published private(set) var status: Status = .off
    @Published private(set) var isSyncing = false
    @Published private(set) var problem: Problem?
    /// Whether the person is signing in to this source in its window.
    @Published private(set) var isSigningIn = false

    private let settings: SettingsStore
    private let store: DirectMessageStore
    private let defaults: UserDefaults
    private let runner: Runner
    private let now: @Sendable () -> Date
    private var state: SignInState
    /// Counts the times the source was switched off, so a sync that began before one is
    /// dropped when it ends.
    private var generation = 0
    private var inFlight: Task<DirectMessageSync.Outcome?, Never>?
    /// The sign-in the person has open.
    private weak var signIn: DirectMessageSignInModel?
    /// The removal of the session after the source was switched off. Nothing loads a page on
    /// the source's store until it has ended, or it would delete the session that page makes.
    private var removal: Task<Void, Never>?

    init(
        source: DirectMessageSource,
        settings: SettingsStore,
        store: DirectMessageStore,
        defaults: UserDefaults,
        dataStore: WKWebsiteDataStore,
        runner: @escaping Runner,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.settings = settings
        self.store = store
        self.defaults = defaults
        self.dataStore = dataStore
        self.runner = runner
        self.now = now
        state = Self.loadState(source: source.id, from: defaults)
        refresh()
    }

    /// The sync the app makes: the source's request rules compiled, then the inbox loaded with
    /// them. A source whose rules WebKit will not take is not loaded at all, since the page
    /// would then be free to connect as it does in front of a person.
    static func standardRunner(dataStore: WKWebsiteDataStore) -> Runner {
        { source in
            guard let rules = await RequestBlocking.compile(
                identifier: "direct-messages-\(source.id)",
                rules: source.blockedRequests
            ) else { return nil }
            return await DirectMessageSync.run(source: source, dataStore: dataStore, contentRules: [rules])
        }
    }

    var isEnabled: Bool { settings.provisorReadsDirectMessages }

    /// The snapshot the last successful sync left, while the source is switched on.
    func snapshot() -> DirectMessageSnapshot? {
        isEnabled ? store.read(source: source.id) : nil
    }

    // MARK: Switching on and off

    /// Switching the source off stops a sync under way, closes the sign-in window, and deletes
    /// the copied chats and the session this Mac holds, so nothing of it stays on disk and
    /// switching it on again starts with a sign-in. The source's own record of the login is
    /// the source's; only the person can end it there.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        settings.provisorReadsDirectMessages = enabled
        if !enabled {
            generation += 1
            store.remove(source: source.id)
            state = SignInState()
            saveState()
            problem = nil
            signIn?.close()
            let running = inFlight
            running?.cancel()
            let earlier = removal
            removal = Task { [dataStore, id = source.id] in
                // The session is removed once no browser of this source is left to write it
                // back: a cancelled sync closes its browser as it ends.
                await earlier?.value
                _ = await running?.value
                await dataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast
                )
                AppLog.notice(.provisor, "direct messages \(id): switched off, copy and session removed")
            }
        }
        refresh()
    }

    /// Returns once the session of an earlier switch-off is gone. A page loaded on the source's
    /// store before then would have its session deleted under it.
    func sessionSettled() async {
        await removal?.value
    }

    // MARK: Syncing

    /// Why a sync would not start now, or nil when it would.
    static func refusal(
        enabled: Bool,
        state: SignInState,
        isSigningIn: Bool,
        isSyncing: Bool
    ) -> Refusal? {
        guard enabled else { return .off }
        guard state.signedIn != nil else { return .notSignedIn }
        if state.needsPerson { return .needsYou }
        if isSigningIn { return .signingIn }
        if isSyncing { return .alreadySyncing }
        return nil
    }

    /// Copies the source's recent chats, when the source is on, signed in, and idle. Returns
    /// how the sync ended; nil when none was started or its result was dropped.
    @discardableResult
    func sync() async -> DirectMessageSync.Outcome? {
        if let refusal = Self.refusal(
            enabled: isEnabled,
            state: state,
            isSigningIn: isSigningIn,
            isSyncing: isSyncing
        ) {
            // A caller that finds a sync under way waits for it, so a pass never starts on a
            // snapshot that is about to be replaced.
            if refusal == .alreadySyncing, let inFlight { return await inFlight.value }
            return nil
        }
        return await runSync(recordsSignIn: false)
    }

    /// Checks a sign-in the person says they finished, by making a sync. The source counts as
    /// signed in when its inbox loaded without asking for a sign-in.
    func confirmSignIn() async -> DirectMessageSync.Outcome? {
        // Each wait can end with another caller's sync already begun, so the wait is repeated
        // until none is under way.
        while let inFlight { _ = await inFlight.value }
        guard isEnabled else { return nil }
        return await runSync(recordsSignIn: true)
    }

    private func runSync(recordsSignIn: Bool) async -> DirectMessageSync.Outcome? {
        let started = generation
        isSyncing = true
        // The removal is read here: one begun later waits for this sync, and must not be
        // waited for by it.
        let pending = removal
        let task = Task { [runner, source] () -> DirectMessageSync.Outcome? in
            await pending?.value
            guard started == self.generation else {
                return self.finish(nil, started: started, recordsSignIn: recordsSignIn)
            }
            let result = await runner(source)
            return self.finish(result, started: started, recordsSignIn: recordsSignIn)
        }
        inFlight = task
        let outcome = await task.value
        return outcome
    }

    private func finish(
        _ result: DirectMessageSync.Result?,
        started: Int,
        recordsSignIn: Bool
    ) -> DirectMessageSync.Outcome? {
        isSyncing = false
        inFlight = nil
        guard started == generation, isEnabled else { return nil }
        defer { refresh() }
        guard let result else {
            problem = .limitsUnavailable
            AppLog.error(.provisor, "direct messages \(source.id): request rules did not compile")
            return nil
        }
        switch result.outcome {
        case .synced:
            state.needsPerson = false
            if recordsSignIn { state.signedIn = now() }
            do {
                if let snapshot = result.snapshot { try store.write(snapshot) }
                problem = nil
            } catch {
                problem = .notSaved
            }
        case .needsSignIn:
            // A sign-in the person has not finished leaves a source that was never signed in
            // as it was.
            if state.signedIn != nil { state.needsPerson = true }
            problem = nil
        case .nothingCaptured:
            state.needsPerson = false
            if recordsSignIn { state.signedIn = now() }
            problem = .nothingCaptured
        case .pageUnavailable:
            problem = .pageUnavailable
        }
        saveState()
        AppLog.notice(.provisor, Self.logLine(source: source.id, result: result))
        return result.outcome
    }

    /// One line for the log: how the sync ended, with counts. The chats and messages are those
    /// of the snapshot.
    static func logLine(source: String, result: DirectMessageSync.Result) -> String {
        let report = result.report
        let threads = result.snapshot?.threads ?? []
        return "direct messages \(source): \(result.outcome.rawValue), "
            + "\(threads.count) chats, \(threads.reduce(0) { $0 + $1.messages.count }) messages, "
            + "\(report.responses) responses, \(report.refusedOperations.values.reduce(0, +)) refused, "
            + "\(report.blockedSockets) sockets blocked"
    }

    // MARK: Signing in

    /// Called by a sign-in as it begins. It is the one a switch-off closes.
    func signInBegan(_ model: DirectMessageSignInModel) {
        signIn = model
        if !isSigningIn { isSigningIn = true }
    }

    /// Called by a sign-in as it closes. One that a newer sign-in replaced changes nothing.
    func signInEnded(_ model: DirectMessageSignInModel) {
        guard signIn == nil || signIn === model else { return }
        signIn = nil
        if isSigningIn { isSigningIn = false }
    }

    // MARK: State

    /// Reads the status again from the setting, the stored sign-in, and the snapshot.
    func refresh() {
        let current = Self.status(
            enabled: isEnabled,
            state: state,
            snapshot: isEnabled ? store.read(source: source.id) : nil
        )
        if current != status { status = current }
    }

    static func status(enabled: Bool, state: SignInState, snapshot: DirectMessageSnapshot?) -> Status {
        guard enabled else { return .off }
        guard state.signedIn != nil else { return .notSignedIn }
        if state.needsPerson { return .needsYou }
        return .signedIn(lastSync: snapshot?.syncedAt, chats: snapshot?.threads.count ?? 0)
    }

    private static func signedInKey(_ source: String) -> String { "provisor.directMessages.\(source).signedIn" }
    private static func needsPersonKey(_ source: String) -> String { "provisor.directMessages.\(source).needsPerson" }

    static func loadState(source: String, from defaults: UserDefaults) -> SignInState {
        let signedIn = (defaults.object(forKey: signedInKey(source)) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return SignInState(
            signedIn: signedIn,
            needsPerson: signedIn != nil && defaults.bool(forKey: needsPersonKey(source))
        )
    }

    private func saveState() {
        if let signedIn = state.signedIn {
            defaults.set(signedIn.timeIntervalSince1970, forKey: Self.signedInKey(source.id))
        } else {
            defaults.removeObject(forKey: Self.signedInKey(source.id))
        }
        defaults.set(state.needsPerson, forKey: Self.needsPersonKey(source.id))
    }
}
