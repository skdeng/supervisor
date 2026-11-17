import Foundation
import WebKit

/// Adds a site while the user watches: the app signs in as far as it recognises each page, the
/// user finishes in the page themselves, and what happened becomes the site's grant.
///
/// The browser is shown to the user, so its policy admits any `https` host and the address bar
/// they would read is `currentHost` and `currentIsSecure`. Nothing is stored here: `finish`
/// hands the grant and record to the caller.
///
/// From `begin` until the page the sign-in leads to, the app examines each page the browser
/// finishes loading, whoever loaded it: it fills the kinds it has not filled yet where it
/// recognises them, and leaves a challenge or a page it does not recognise to the user, whose
/// next page it examines afresh. The typed secrets live from `begin` until `finish` succeeds or
/// `cancel()` is called, which the window calls when it closes.
///
/// **The saved password is the one that worked.** `finish` builds the grant from the password
/// given to `begin`, so it refuses unless the app filled that password and the sign-in then
/// left the password form, with no page asking for it again and no typing by the person into
/// a password field on the page (`passwordIsConfirmed`).
///
/// `beginKeepingSession` and `finishKeepingSession` are the same enrollment with no secrets:
/// the person signs in on the page themselves, the app fills nothing, and the grant keeps the
/// browser session alone (`SiteGrant.remembersPassword == false`).
///
/// **A kept session must have crossed a sign-in.** A page with no password field reads as
/// signed in to the probe, and a public home page has none. So while a session is being kept,
/// each finished page is probed, and `finishKeepingSession` refuses (`signInNotSeen`) unless
/// some page of this enrollment showed a password field, a code field, or a sign-in frame, or
/// the person typed into a password field, before the signed-in page it saves.
@MainActor
final class SiteEnrollment: ObservableObject {
    enum Failure: Error, Equatable {
        /// The address is not an `https` address on a valid host with no port or credentials.
        case invalidAddress
        /// The page is not one that shows the user signed in.
        case notSignedIn
        /// What was observed does not make a valid grant.
        case invalidGrant
        /// The app filled the password, but the site asked for it again or the person typed a
        /// password into the page, so which password worked is unknown.
        case passwordNotConfirmed
        /// The app filled no password, so it has no sign-in it could replay.
        case passwordNotFilled
        /// The enrollment was cancelled while it finished.
        case cancelled
        /// No page of a kept session asked for a sign-in, so nothing shows the person signed in.
        case signInNotSeen
    }

    /// What the app says about where it stands.
    enum Notes {
        static let signingIn = "Signing in for you."
        static let finishYourself = "Finish signing in in the page, then save the site."
        static let checkAndSave = "If the page shows you are signed in, save the site."
        static let signInYourself = "Sign in on the page, then save the site."
    }

    @Published private(set) var isWorking = false
    /// The main frame's host, for display.
    @Published private(set) var currentHost: String?
    @Published private(set) var currentIsSecure = false
    /// A fixed sentence about what the app is waiting for.
    @Published private(set) var note: String?
    /// The handle texted codes came from, learned from the first code that arrived; the window
    /// shows it for the user to confirm.
    @Published private(set) var learnedCodeSender: String?
    /// See the type's discussion; false from `begin` until the sign-in shows the password took.
    @Published private(set) var passwordIsConfirmed = false
    /// A saved secret the app declined to fill because the page was on another host.
    @Published private(set) var unvettedFill: AssistedSignInSession.UnvettedFill?
    /// Set by `cancel()`; nothing the enrollment did is used afterwards.
    private(set) var isCancelled = false

    let browser: SiteBrowser

    /// What the user typed. It carries secrets, so no rendering of it shows them.
    private struct Pending: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let signInURL: URL
        let username: String
        let password: String
        let authenticatorKey: String?
        let codeKind: SiteGrant.CodeKind
        let codeSender: String?

        var description: String { "Pending(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: []) }
    }

    private let codes: SignInCodes
    private let codeWaitLimit: Duration
    private var pending: Pending?
    /// The address `beginKeepingSession` loaded; nil otherwise.
    private var keptSessionURL: URL?
    private var session: AssistedSignInSession?
    private var broker: SignInBroker?
    private var isBeginning = false
    private var isArmed = false
    private var assistTask: Task<Void, Never>?
    private var assistRequested = false
    private var passwordTyped = false
    /// The hosts navigations went through up to the first page past the sign-in, once there.
    private var hostsAtSignIn: Set<String>?
    /// Whether a page of the kept session asked for a sign-in, or the person typed a password.
    private var keptSessionSawSignIn = false
    private var observeTask: Task<Void, Never>?
    private var observeRequested = false

    init(
        dataStore: WKWebsiteDataStore = SiteBrowser.sharedStore,
        codes: SignInCodes,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit
    ) {
        self.codes = codes
        self.codeWaitLimit = codeWaitLimit
        browser = SiteBrowser(
            policy: .anyHTTPSHost,
            dataStore: dataStore,
            simulatedPages: simulatedPages,
            settling: settling,
            observesPasswordTyping: true
        )
        browser.locationObserver = { [weak self] in
            self?.refreshLocation()
        }
        browser.pageFinishedObserver = { [weak self] in
            self?.pageFinished()
        }
        browser.passwordTypedObserver = { [weak self] in
            self?.passwordTyped = true
            if self?.keptSessionURL != nil { self?.keptSessionSawSignIn = true }
            self?.refreshPasswordConfirmation()
        }
    }

    /// The address as an `https` URL, or nil: a missing scheme becomes `https`, and anything
    /// else that is not `https`, or has a port, credentials, or a host that is not a plain DNS
    /// name, is refused. The fragment is dropped.
    static func normalisedAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              SiteHost.isValid(host)
        else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        return components.url
    }

    /// Loads the sign-in page and lets the app fill what it recognises. The user may type in the
    /// page at any time; the app goes on examining the pages the browser loads until `finish`.
    ///
    /// `passwordHosts` and `authenticatorHosts` are for secrets saved with a site rather than
    /// typed now: such a secret is filled only on those hosts (see `AssistedSignInSession`).
    func begin(
        signInAddress: String,
        username: String,
        password: String,
        authenticatorKey: String?,
        codeKind: SiteGrant.CodeKind,
        codeSender: String?,
        passwordHosts: [String]? = nil,
        authenticatorHosts: [String]? = nil
    ) async throws {
        guard let url = Self.normalisedAddress(signInAddress) else { throw Failure.invalidAddress }
        stopAssisting()
        stopObserving()
        keptSessionURL = nil
        pending = Pending(
            signInURL: url,
            username: username,
            password: password,
            authenticatorKey: authenticatorKey,
            codeKind: codeKind,
            codeSender: codeSender
        )
        let broker = SignInBroker(browser: browser, codeWaitLimit: codeWaitLimit)
        self.broker = broker
        session = AssistedSignInSession(
            broker: broker,
            username: username,
            password: password,
            authenticatorKey: authenticatorKey,
            codeKind: codeKind,
            codeSender: codeSender,
            codes: codes,
            passwordHosts: passwordHosts,
            authenticatorHosts: authenticatorHosts
        )
        hostsAtSignIn = nil
        learnedCodeSender = nil
        unvettedFill = nil
        passwordTyped = false
        passwordIsConfirmed = false
        isBeginning = true
        note = Notes.signingIn
        refreshWorking()
        defer {
            isBeginning = false
            refreshWorking()
        }

        do {
            _ = try await browser.open(url)
        } catch SiteBrowser.Failure.notAllowed {
            wipe()
            throw Failure.invalidAddress
        } catch {
            note = Notes.finishYourself
            throw error
        }
        isArmed = true
        requestAssist()
        await idle()
    }

    /// Loads the sign-in page for the person to sign in on themselves. Nothing is filled and
    /// no secret is held; the hosts the browser passes through are recorded as for `begin`.
    func beginKeepingSession(signInAddress: String) async throws {
        guard let url = Self.normalisedAddress(signInAddress) else { throw Failure.invalidAddress }
        stopAssisting()
        stopObserving()
        pending = nil
        session = nil
        keptSessionURL = url
        keptSessionSawSignIn = false
        broker = SignInBroker(browser: browser, codeWaitLimit: codeWaitLimit)
        hostsAtSignIn = nil
        learnedCodeSender = nil
        unvettedFill = nil
        passwordTyped = false
        passwordIsConfirmed = false
        isBeginning = true
        note = Notes.signInYourself
        refreshWorking()
        defer {
            isBeginning = false
            refreshWorking()
        }

        do {
            _ = try await browser.open(url)
        } catch SiteBrowser.Failure.notAllowed {
            wipe()
            throw Failure.invalidAddress
        }
        requestObservation()
        await idle()
    }

    /// The user says they are signed in: builds the grant from what was observed.
    ///
    /// The page is read afresh (`signedInPage`). The start page is that page without its query
    /// and fragment; the browse hosts are the hosts the sign-in went through; the fill hosts
    /// are the sign-in host and the hosts the filled pages and forms belong to. A refusal
    /// leaves the enrollment as it was.
    ///
    /// A texted or emailed code with no sender known, on a sign-in that never showed a code
    /// field, is saved as no code: the site did not ask for one this time.
    func finish(name: String) async throws -> (grant: SiteGrant, record: SiteRecord) {
        guard !isCancelled else { throw Failure.cancelled }
        guard let pending, let session, let broker else { throw Failure.notSignedIn }
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
        await idle()
        var succeeded = false
        defer {
            if !succeeded, self.pending != nil { isArmed = true }
        }

        let page = try await signedInPage(broker: broker)
        guard session.steps.contains(where: { $0.kind == .password }) else {
            throw Failure.passwordNotFilled
        }
        guard passwordIsConfirmed else { throw Failure.passwordNotConfirmed }

        let (startURL, startHost, probe) = (page.startURL, page.startHost, page.probe)
        guard let signInHost = pending.signInURL.host(percentEncoded: false)?.lowercased() else {
            throw Failure.invalidGrant
        }

        let steps = session.steps
        var fillHosts = [signInHost]
        for host in steps.map({ String($0.origin.dropFirst("https://".count)) }) + session.submissionHosts
        where !fillHosts.contains(host) {
            fillHosts.append(host)
        }
        guard fillHosts.allSatisfy(SiteHost.isValid) else { throw Failure.invalidGrant }

        let browseHosts = browseHosts(required: Set(fillHosts).union([signInHost, startHost]))

        var codeKind = pending.codeKind
        var codeSender: String? = switch pending.codeKind {
        case .text: session.learnedCodeSender ?? pending.codeSender
        case .email: pending.codeSender
        case .none, .authenticator: nil
        }
        if codeKind == .text || codeKind == .email, codeSender == nil, !session.sawCodeField,
           !steps.contains(where: { $0.kind == .code }) {
            codeKind = .none
            codeSender = nil
        }
        let grant = SiteGrant(
            username: pending.username,
            password: pending.password,
            authenticatorKey: codeKind == .authenticator ? pending.authenticatorKey : nil,
            signInURL: pending.signInURL,
            startURL: startURL,
            fillHosts: fillHosts,
            browseHosts: [signInHost] + browseHosts.subtracting([signInHost]).sorted(),
            codeKind: codeKind,
            codeSender: codeSender,
            signInSteps: steps,
            signOutControlSeen: probe.hasSignOutControl
        )
        guard grant.isValid(for: signInHost) else { throw Failure.invalidGrant }

        let label = Proposal.displayText(name, limit: SiteRecord.nameLimit) ?? signInHost
        let record = SiteRecord(id: signInHost, name: label, added: Date(), lastSignedIn: Date())
        succeeded = true
        wipe()
        return (grant, record)
    }

    /// The person says they are signed in: builds a grant that keeps the session and holds no
    /// secret. The page must pass the check `finish` makes (`signedInPage`); the start page and
    /// browse hosts are derived as `finish` derives them, and the only fill host is the
    /// sign-in host. A refusal leaves the enrollment as it was.
    func finishKeepingSession(name: String) async throws -> (grant: SiteGrant, record: SiteRecord) {
        guard !isCancelled else { throw Failure.cancelled }
        guard keptSessionURL != nil, let broker else { throw Failure.notSignedIn }
        await idle()
        // Read again: the enrollment may have been cancelled or begun afresh meanwhile.
        guard !isCancelled else { throw Failure.cancelled }
        guard let signInURL = keptSessionURL else { throw Failure.notSignedIn }
        let page = try await signedInPage(broker: broker)
        guard keptSessionSawSignIn else { throw Failure.signInNotSeen }
        guard let signInHost = signInURL.host(percentEncoded: false)?.lowercased() else {
            throw Failure.invalidGrant
        }

        let browseHosts = browseHosts(required: [signInHost, page.startHost])
        let grant = SiteGrant(
            username: "",
            password: "",
            authenticatorKey: nil,
            signInURL: signInURL,
            startURL: page.startURL,
            fillHosts: [signInHost],
            browseHosts: [signInHost] + browseHosts.subtracting([signInHost]).sorted(),
            codeKind: .none,
            codeSender: nil,
            signInSteps: [],
            signOutControlSeen: page.probe.hasSignOutControl,
            remembersPassword: false
        )
        guard grant.isValid(for: signInHost) else { throw Failure.invalidGrant }

        let label = Proposal.displayText(name, limit: SiteRecord.nameLimit) ?? signInHost
        var record = SiteRecord(id: signInHost, name: label, added: Date(), lastSignedIn: Date())
        record.keepsSessionOnly = true
        wipe()
        return (grant, record)
    }

    /// The page on display, read afresh, when it shows the user signed in: an `https` page on
    /// a valid host, done loading, with no password field, no field that asks for a code, and
    /// no large sign-in frame. Returns it as a start page, without its query and fragment.
    private func signedInPage(
        broker: SignInBroker
    ) async throws -> (startURL: URL, startHost: String, probe: PageProbe) {
        guard !browser.webView.isLoading,
              let current = browser.currentURL,
              current.scheme?.lowercased() == "https",
              current.port == nil,
              var components = URLComponents(url: current, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let startHost = current.host(percentEncoded: false)?.lowercased(),
              SiteHost.isValid(startHost),
              let probe = try? await broker.probe(),
              probe.isSecureTopFrame,
              SignInRules.isPastSignIn(probe)
        else { throw isCancelled ? Failure.cancelled : Failure.notSignedIn }
        guard !isCancelled else { throw Failure.cancelled }
        components.query = nil
        components.fragment = nil
        guard let startURL = components.url else { throw Failure.invalidGrant }
        return (startURL, startHost, probe)
    }

    /// `required` with the hosts the sign-in went through, unless together they would be more
    /// than a grant may hold.
    private func browseHosts(required: Set<String>) -> Set<String> {
        let observed = (hostsAtSignIn ?? browser.traversedHosts.union(browser.visitedHosts))
            .filter(SiteHost.isValid)
        let all = required.union(observed)
        return all.count <= SiteGrant.maximumHosts ? all : required
    }

    /// Stops examining pages, forgets the secrets, and closes the browser. The enrollment is
    /// finished with.
    func cancel() {
        isCancelled = true
        stopAssisting()
        wipe()
        browser.close()
    }

    /// Returns once the app has finished examining the pages loaded so far.
    func idle() async {
        while let task = assistTask ?? observeTask {
            await task.value
        }
    }

    // MARK: Examining pages

    private func wipe() {
        stopObserving()
        keptSessionSawSignIn = false
        isArmed = false
        assistRequested = false
        pending = nil
        keptSessionURL = nil
        session = nil
        broker = nil
    }

    private func stopAssisting() {
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
    }

    private func pageFinished() {
        if isArmed {
            requestAssist()
        } else if keptSessionURL != nil {
            requestObservation()
        }
    }

    // MARK: Watching a kept session

    private func stopObserving() {
        observeRequested = false
        observeTask?.cancel()
    }

    /// Asks for the open page of a kept session to be probed for a sign-in, once the page in
    /// flight, if any, has been. A request made while one runs is met by one more probe.
    private func requestObservation() {
        observeRequested = true
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            while let self, self.keptSessionURL != nil, self.observeRequested, !Task.isCancelled {
                self.observeRequested = false
                await self.observeCurrentPage()
            }
            self?.observeTask = nil
        }
    }

    /// Notes whether the page on display asks for a sign-in: a password field, a code field,
    /// or a sign-in frame. Only the noting is kept, never what the page holds.
    private func observeCurrentPage() async {
        guard let broker, keptSessionURL != nil else { return }
        do {
            try await browser.settleLoadedPage()
        } catch {
            return
        }
        guard !Task.isCancelled, keptSessionURL != nil,
              let probe = try? await broker.probe(),
              !Task.isCancelled, keptSessionURL != nil
        else { return }
        if probe.hasVisiblePassword || probe.hasCodeField || probe.hasLoginFrame {
            keptSessionSawSignIn = true
        }
    }

    /// Asks for the open page to be examined once the page in flight, if any, has been. A
    /// request made while one runs is met by one more examination, not one per request.
    private func requestAssist() {
        assistRequested = true
        guard assistTask == nil else { return }
        assistTask = Task { [weak self] in
            while let self, self.isArmed, self.assistRequested, !Task.isCancelled {
                self.assistRequested = false
                await self.examineCurrentPage()
            }
            self?.assistTask = nil
            self?.refreshWorking()
        }
        refreshWorking()
    }

    private func examineCurrentPage() async {
        guard let session, isArmed, hostsAtSignIn == nil else { return }
        do {
            try await browser.settleLoadedPage()
        } catch {
            return
        }
        guard isArmed, !Task.isCancelled else { return }

        note = Notes.signingIn
        let stopped = await session.run()
        learnedCodeSender = session.learnedCodeSender
        unvettedFill = session.unvettedFill
        refreshPasswordConfirmation()
        if session.hasReachedSignedInPage {
            if hostsAtSignIn == nil { hostsAtSignIn = browser.traversedHosts.union(browser.visitedHosts) }
            note = Notes.checkAndSave
        } else {
            note = stopped == nil ? Notes.checkAndSave : Notes.finishYourself
        }
        AppLog.notice(
            .sites,
            "enrollment sign-in recorded \(session.steps.count) steps, stopped: \(stopped?.rawValue ?? "none")"
        )
    }

    private func refreshWorking() {
        isWorking = isBeginning || assistTask != nil
    }

    private func refreshLocation() {
        let url = browser.committedURL
        let host = url?.host(percentEncoded: false)?.lowercased()
        let secure = url?.scheme?.lowercased() == "https" && browser.webView.hasOnlySecureContent
        if host != currentHost { currentHost = host }
        if secure != currentIsSecure { currentIsSecure = secure }
    }

    private func refreshPasswordConfirmation() {
        let confirmed = session?.passwordWasAccepted == true && !passwordTyped
        if confirmed != passwordIsConfirmed { passwordIsConfirmed = confirmed }
    }
}
