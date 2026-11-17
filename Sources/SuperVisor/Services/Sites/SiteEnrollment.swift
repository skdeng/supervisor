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
/// **A kept session is saved on evidence of a sign-in, or on the person's word.** A page with
/// no password field reads as signed in to the probe, and a public home page has none. So
/// while a session is being kept, the page is probed each time a load finishes and each time
/// the person types into it, and `finishKeepingSession` refuses (`signInNotSeen`) unless some
/// page of this enrollment asked for a sign-in (`SignInRules.asksForSignIn`), the person typed
/// into a password field, the page it saves shows a sign-out control, or the page differs for
/// a visitor (below). A sign-in can leave none of those: a session an earlier window left in
/// the data store, a passkey, a link opened from an email. The person can see the page, so
/// after that refusal their confirmation (`confirming`, the refusal they answered) saves it;
/// such a grant holds no secret, and a mistaken one reads only what the site shows a visitor.
/// A confirmation answers only the refusal it names: a save that would refuse for the other
/// reason refuses with that one.
///
/// **The page is read twice more before it is saved, each in a browser that is never shown**
/// (`HiddenRead`), because the person's window has its own width and moment while every later
/// read is a fresh load at the default size. The first read is on the enrollment's own data
/// store, as a later read would be, and confirms the controls the person's page showed: a
/// sign-out control or a missing sign-in control is recorded in the grant only when this read
/// shows it too (`SessionMarkers`). The second is a visitor's (`VisitorCheck`), made when the
/// grant will record no sign-out control, and compared with the first read when there is one.
/// A visitor who is sent to a sign-in page or shown a sign-in control the page lacks shows
/// that the session is what makes the page the person's: that is evidence of a sign-in, and
/// the last case is recorded as `SiteGrant.signInControlAbsent`, which lets a lapse be
/// noticed later. A page the visitor sees the same way cannot show a lapse, so it is refused
/// (`pageLooksPublic`) even when a sign-in was seen. A read that cannot finish leaves the
/// other rules to decide. An enrollment built with `simulatedPages` and no `visitorPages`
/// makes no visitor check, so that no test reaches the network through it.
///
/// A sign-in that moves from step to step inside one page finishes no load, and one that ends
/// on a button press involves no typing either, so while a session is being kept the page is
/// also probed every `recheckInterval`. What the probes find is published as `appearsSignedIn`,
/// which only advises the window's look; `finishKeepingSession` decides on a fresh read.
///
/// **An enrollment made by `recordingCredentials` also records what the person types** into
/// the user name and password fields of the main frame (`SiteBrowser.Observation`), and only
/// while a sign-in is under way: a session being kept, or an assisted sign-in the person may
/// finish by hand. The values live in one `CredentialCapture`, which every probe of the page on
/// display also informs, which each password fill of the app's own clears for its field, and
/// which `cancel()`, a fresh `begin`, and the end of a save wipe. A successful
/// `finishKeepingSession` judges it once (`CredentialCapture.offer`), and so does
/// `judgeTypedPassword(replacing:)` after an assisted sign-in whose filled password `finish`
/// could not confirm; the judgement, `passwordOffer` or `offerRefusal`, is kept until the
/// enrollment is cancelled or begun afresh. `passwordGrant(upgrading:)` and
/// `replacementGrant(for:)` turn an offer into a grant that signs in by itself. Any other
/// enrollment records nothing and never has an offer.
///
/// **An enrollment for the sign-in window probes the page of an assisted sign-in** as a kept
/// session's is probed (`watchesAssistedSignIn`: one made by `recordingCredentials` or
/// `watchingSignIn`), which sets `appearsSignedIn`, and keeps the capture informed when it
/// records. The Add Site form's enrollment does not.
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
        /// Nothing the app observed shows the person signed in, and they have not confirmed it.
        case signInNotSeen
        /// The page reads the same to a visitor who is not signed in, so it cannot show that the
        /// session has lapsed, and the person has not confirmed it.
        case pageLooksPublic

        var caseName: String {
            switch self {
            case .invalidAddress: "invalidAddress"
            case .notSignedIn: "notSignedIn"
            case .invalidGrant: "invalidGrant"
            case .passwordNotConfirmed: "passwordNotConfirmed"
            case .passwordNotFilled: "passwordNotFilled"
            case .cancelled: "cancelled"
            case .signInNotSeen: "signInNotSeen"
            case .pageLooksPublic: "pageLooksPublic"
            }
        }
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
    /// Whether the page on display looks past the sign-in: a secure top frame that asks for no
    /// sign-in, after a sign-in seen in this enrollment or showing a sign-out control. False
    /// whenever the page is not being probed (`observesPages`).
    @Published private(set) var appearsSignedIn = false
    /// Set by `cancel()`; nothing the enrollment did is used afterwards.
    private(set) var isCancelled = false
    /// Whether a probed page of the sign-in asked for a sign-in, or the person typed a password.
    private(set) var sawSignIn = false

    static let standardRecheckInterval: Duration = .seconds(2)

    let browser: SiteBrowser
    /// Whether a page that shows no sign-out control is loaded as a visitor would load it. False
    /// for an enrollment on simulated pages that has no simulated visitor site.
    let checksVisitor: Bool
    /// Whether the enrollment was made by `recordingCredentials`.
    let recordsCredentials: Bool
    /// Whether the page of an assisted sign-in is probed as a kept session's is (`observesPages`):
    /// for an enrollment made by `recordingCredentials` or `watchingSignIn`.
    let watchesAssistedSignIn: Bool

    /// What the person typed during the sign-in under way, a session being kept or an assisted
    /// sign-in.
    private var capture = CredentialCapture()

    /// A judgement of the capture and the grant an offer builds on.
    private enum Judgement {
        /// Made by a successful `finishKeepingSession` against `session`, the grant it returned;
        /// `passwordGrant(upgrading:)` of that same grant builds on it.
        case keptSession(Result<PasswordOffer, OfferRefusal>, session: SiteGrant)
        /// Made by `judgeTypedPassword(replacing:)` for a password typed on one of `stored`'s fill
        /// hosts; `replacementGrant(for:)` swaps it into `stored`.
        case newPassword(Result<PasswordOffer, OfferRefusal>, stored: SiteGrant)
        /// Made by `judgeTypedPassword(replacing:)` for a password typed anywhere else, against
        /// `session`, the grant that keeps the session on display; `replacementGrant(for:)`
        /// builds a grant from the typed fields on it.
        case movedSignIn(Result<PasswordOffer, OfferRefusal>, session: SiteGrant, stored: SiteGrant)

        var result: Result<PasswordOffer, OfferRefusal> {
            switch self {
            case let .keptSession(result, _), let .newPassword(result, _), let .movedSignIn(result, _, _): result
            }
        }
    }

    /// The last judgement made, kept until the enrollment is cancelled or begun afresh.
    private var judgement: Judgement?
    private var endHandlers: [@MainActor () -> Void] = []

    /// The offer to keep the password typed into the page, from the last judgement of an
    /// enrollment that records credentials: a successful `finishKeepingSession`, or
    /// `judgeTypedPassword(replacing:)`.
    var passwordOffer: PasswordOffer? {
        guard case let .success(offer)? = judgement?.result else { return nil }
        return offer
    }

    /// Why the last judgement of an enrollment that records credentials made no offer.
    var offerRefusal: OfferRefusal? {
        guard case let .failure(refusal)? = judgement?.result else { return nil }
        return refusal
    }

    /// The user name the grant `replacementGrant(for:)` would build holds, for display; nil when
    /// it holds none or there is no such offer.
    var replacementUsername: String? {
        let username: String
        switch judgement {
        case let .newPassword(.success, stored)?:
            username = stored.username
        case let .movedSignIn(.success(offer), _, stored)?:
            username = offer.usernameText ?? stored.username
        default:
            return nil
        }
        return username.isEmpty ? nil : username
    }

    /// Whether the password `begin` was given was filled and the sign-in then left its form with
    /// no page asking for it again (`AssistedSignInSession.passwordWasAccepted`).
    var filledPasswordWasAccepted: Bool {
        session?.passwordWasAccepted == true
    }

    /// What the user typed. It carries secrets, so no rendering of it shows them.
    private struct Pending: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let signInURL: URL
        let username: String
        /// Nil when the password is withheld from the app's fills.
        let password: String?
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
    /// Set once a Done has reached an answer for the person: no saved secret is filled again
    /// until the enrollment begins afresh.
    private var fillsEnded = false
    /// Whether the person typed into a password field since the app last filled one.
    private var passwordTyped = false
    /// The hosts navigations went through up to the first page past the sign-in, once there.
    private var hostsAtSignIn: Set<String>?
    private let recheckInterval: Duration
    private let settling: SiteBrowser.Settling
    private let dataStore: WKWebsiteDataStore
    private let simulatedPages: SiteBrowser.SimulatedPages?
    private let visitorPages: SiteBrowser.SimulatedPages?
    private let visitorRecheckDelay: Duration
    /// The hidden reads of a page about to be saved, while they run.
    private var sessionReadTask: Task<SessionReads, Never>?
    private var isReadingSession = false
    /// Counts each time the enrollment begins afresh or is wiped, so that a save can tell that
    /// what it set out to save has gone.
    private var generation = 0
    /// The timed re-probe of a kept session's page; it holds the enrollment only while it acts.
    private var recheckTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var observeRequested = false
    /// Whether a pending observation waits for the page to settle before it probes.
    private var observeSettles = false

    /// An enrollment that records nothing the person types.
    convenience init(
        dataStore: WKWebsiteDataStore = SiteBrowser.sharedStore,
        codes: SignInCodes,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit,
        recheckInterval: Duration = SiteEnrollment.standardRecheckInterval,
        visitorPages: SiteBrowser.SimulatedPages? = nil,
        visitorRecheckDelay: Duration = VisitorCheck.standardRecheckDelay
    ) {
        self.init(
            observation: .typing,
            watchesAssistedSignIn: false,
            dataStore: dataStore,
            codes: codes,
            simulatedPages: simulatedPages,
            settling: settling,
            codeWaitLimit: codeWaitLimit,
            recheckInterval: recheckInterval,
            visitorPages: visitorPages,
            visitorRecheckDelay: visitorRecheckDelay
        )
    }

    /// An enrollment for the sign-in window that records nothing the person types and probes
    /// the page of an assisted sign-in, so `appearsSignedIn` advises the window as it does for a
    /// kept session.
    static func watchingSignIn(
        dataStore: WKWebsiteDataStore = SiteBrowser.sharedStore,
        codes: SignInCodes,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit,
        recheckInterval: Duration = SiteEnrollment.standardRecheckInterval,
        visitorPages: SiteBrowser.SimulatedPages? = nil,
        visitorRecheckDelay: Duration = VisitorCheck.standardRecheckDelay
    ) -> SiteEnrollment {
        SiteEnrollment(
            observation: .typing,
            watchesAssistedSignIn: true,
            dataStore: dataStore,
            codes: codes,
            simulatedPages: simulatedPages,
            settling: settling,
            codeWaitLimit: codeWaitLimit,
            recheckInterval: recheckInterval,
            visitorPages: visitorPages,
            visitorRecheckDelay: visitorRecheckDelay
        )
    }

    /// An enrollment for the sign-in window that records the user name and password the person
    /// types while a session is kept or an assisted sign-in is under way, and probes the page
    /// of either (see the type's discussion).
    static func recordingCredentials(
        dataStore: WKWebsiteDataStore = SiteBrowser.sharedStore,
        codes: SignInCodes,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit,
        recheckInterval: Duration = SiteEnrollment.standardRecheckInterval,
        visitorPages: SiteBrowser.SimulatedPages? = nil,
        visitorRecheckDelay: Duration = VisitorCheck.standardRecheckDelay
    ) -> SiteEnrollment {
        SiteEnrollment(
            observation: .typingAndCredentials,
            watchesAssistedSignIn: true,
            dataStore: dataStore,
            codes: codes,
            simulatedPages: simulatedPages,
            settling: settling,
            codeWaitLimit: codeWaitLimit,
            recheckInterval: recheckInterval,
            visitorPages: visitorPages,
            visitorRecheckDelay: visitorRecheckDelay
        )
    }

    private init(
        observation: SiteBrowser.Observation,
        watchesAssistedSignIn: Bool,
        dataStore: WKWebsiteDataStore,
        codes: SignInCodes,
        simulatedPages: SiteBrowser.SimulatedPages?,
        settling: SiteBrowser.Settling,
        codeWaitLimit: Duration,
        recheckInterval: Duration,
        visitorPages: SiteBrowser.SimulatedPages?,
        visitorRecheckDelay: Duration
    ) {
        recordsCredentials = observation == .typingAndCredentials
        self.watchesAssistedSignIn = watchesAssistedSignIn
        self.codes = codes
        self.codeWaitLimit = codeWaitLimit
        self.recheckInterval = recheckInterval
        self.settling = settling
        self.dataStore = dataStore
        self.simulatedPages = simulatedPages
        self.visitorPages = visitorPages
        self.visitorRecheckDelay = visitorRecheckDelay
        checksVisitor = simulatedPages == nil || visitorPages != nil
        browser = SiteBrowser(
            policy: .anyHTTPSHost,
            dataStore: dataStore,
            simulatedPages: simulatedPages,
            settling: settling,
            observation: observation
        )
        if recordsCredentials {
            browser.credentialObserver = { [weak self] credential in
                guard let self, self.isSigningIn else { return }
                self.capture.record(credential)
            }
        }
        browser.locationObserver = { [weak self] in
            self?.refreshLocation()
        }
        browser.pageFinishedObserver = { [weak self] in
            self?.pageFinished()
        }
        browser.passwordTypedObserver = { [weak self] in
            guard let self else { return }
            self.passwordTyped = true
            if self.observesPages { self.sawSignIn = true }
            self.refreshPasswordConfirmation()
        }
        // A sign-in that moves from step to step inside one page finishes no load, so the
        // fields of a later step are met only by looking again while the person types. The
        // look is immediate: a code field that submits on its last digit is gone within the
        // time a page takes to settle.
        browser.typedObserver = { [weak self] in
            if self?.observesPages == true { self?.requestObservation(settling: false) }
        }
    }

    /// Whether a sign-in is under way: a session being kept, or an assisted sign-in.
    private var isSigningIn: Bool {
        keptSessionURL != nil || pending != nil
    }

    /// Whether the page on display is probed as it changes: while a session is kept, and during
    /// an assisted sign-in of an enrollment made for the sign-in window
    /// (`watchesAssistedSignIn`).
    private var observesPages: Bool {
        keptSessionURL != nil || (watchesAssistedSignIn && pending != nil)
    }

    /// An enrollment freed without being cancelled still ends, so nothing waiting on its end
    /// (`whenEnded`) is left waiting.
    isolated deinit {
        let handlers = endHandlers
        endHandlers = []
        handlers.forEach { $0() }
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
    /// typed now: such a secret, and the user name with the password, is filled only on those
    /// hosts (see `AssistedSignInSession`). A nil `password` is withheld: no password field is
    /// filled, and a form that asks for one is left to the person. A cancelled enrollment throws
    /// `cancelled` and starts nothing.
    ///
    /// Each time the app fills a password field it replaces what the person had typed there, so
    /// that typing no longer counts against the filled password (`passwordIsConfirmed`) and is
    /// dropped from what an offer is made of.
    func begin(
        signInAddress: String,
        username: String,
        password: String?,
        authenticatorKey: String?,
        codeKind: SiteGrant.CodeKind,
        codeSender: String?,
        passwordHosts: [String]? = nil,
        authenticatorHosts: [String]? = nil
    ) async throws {
        guard !isCancelled else { throw Failure.cancelled }
        guard let url = Self.normalisedAddress(signInAddress) else { throw Failure.invalidAddress }
        generation += 1
        stopAssisting()
        stopObserving()
        forgetCredentials()
        keptSessionURL = nil
        appearsSignedIn = false
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
        session?.onFilled = { [weak self] step in
            self?.appFilled(step)
        }
        fillsEnded = false
        hostsAtSignIn = nil
        learnedCodeSender = nil
        unvettedFill = nil
        passwordTyped = false
        passwordIsConfirmed = false
        sawSignIn = false
        isBeginning = true
        note = Notes.signingIn
        if observesPages { startRechecking() }
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
        if observesPages { requestObservation(settling: true) }
        await idle()
    }

    /// Loads the sign-in page for the person to sign in on themselves. Nothing is filled and
    /// no secret is held; the hosts the browser passes through are recorded as for `begin`.
    /// A cancelled enrollment throws `cancelled` and starts nothing.
    func beginKeepingSession(signInAddress: String) async throws {
        guard !isCancelled else { throw Failure.cancelled }
        guard let url = Self.normalisedAddress(signInAddress) else { throw Failure.invalidAddress }
        generation += 1
        stopAssisting()
        stopObserving()
        forgetCredentials()
        pending = nil
        session = nil
        keptSessionURL = url
        sawSignIn = false
        appearsSignedIn = false
        broker = SignInBroker(browser: browser, codeWaitLimit: codeWaitLimit)
        hostsAtSignIn = nil
        learnedCodeSender = nil
        unvettedFill = nil
        passwordTyped = false
        passwordIsConfirmed = false
        isBeginning = true
        note = Notes.signInYourself
        startRechecking()
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
        requestObservation(settling: true)
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
    ///
    /// It ends the app's work on the page first, a wait for a code or a fill in flight
    /// included. A refusal hands the page back to the app, which looks at it again at once when
    /// the page still asks for a sign-in (`notSignedIn`).
    func finish(name: String) async throws -> (grant: SiteGrant, record: SiteRecord) {
        guard !isCancelled else { throw Failure.cancelled }
        guard let pending, let session, let broker else { throw Failure.notSignedIn }
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
        await idle()
        var succeeded = false
        var looksAgain = false
        defer {
            if !succeeded { rearm(lookingAgain: looksAgain) }
        }

        let page: (startURL: URL, startHost: String, probe: PageProbe)
        do {
            page = try await signedInPage(broker: broker)
        } catch Failure.notSignedIn {
            looksAgain = true
            throw Failure.notSignedIn
        }
        guard session.steps.contains(where: { $0.kind == .password }), let password = pending.password else {
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
            password: password,
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

    /// What shows that a kept session is a signed-in one, strongest first.
    enum KeptSessionBasis: Equatable {
        /// A page of the enrollment asked for a sign-in, or the person typed a password.
        case sighting
        /// The page being saved shows a sign-out control.
        case signOutControl
        /// A visitor with no cookies is sent to a sign-in page, asked to sign in, or shown a
        /// sign-in control the page being saved lacks.
        case visitorDiffers
        /// Nothing the app observed; the person confirmed it.
        case personsWord

        /// The refusal a page earns before anyone confirms it, or nil when it has a basis. A
        /// page a visitor sees the same way (`looksTheSame`) shows nothing, whatever else was
        /// seen, since the person may have signed in and then moved to a public page.
        static func refusal(
            sawSignIn: Bool,
            showsSignOutControl: Bool,
            visitor: VisitorVerdict?
        ) -> Failure? {
            if visitor == .looksTheSame { return .pageLooksPublic }
            if sawSignIn || showsSignOutControl || visitor?.differsFromSignedIn == true { return nil }
            return .signInNotSeen
        }

        /// The basis a page is saved on, or the refusal that stands. `confirming` is the refusal
        /// the person answered: it saves the page only when it is the refusal the page earns.
        static func decide(
            sawSignIn: Bool,
            showsSignOutControl: Bool,
            visitor: VisitorVerdict? = nil,
            confirming: Failure? = nil
        ) -> Result<KeptSessionBasis, Failure> {
            if let refusal = refusal(
                sawSignIn: sawSignIn,
                showsSignOutControl: showsSignOutControl,
                visitor: visitor
            ) {
                return confirming == refusal ? .success(.personsWord) : .failure(refusal)
            }
            if sawSignIn { return .success(.sighting) }
            return .success(showsSignOutControl ? .signOutControl : .visitorDiffers)
        }
    }

    /// What a grant records about the page it was saved on, which later reads compare with.
    struct SessionMarkers: Equatable {
        /// Whether a later read must show a sign-out control.
        let signOutControlSeen: Bool
        /// Whether a later read must show no sign-in control.
        let signInControlAbsent: Bool
    }

    /// The markers for a page the person saw as `person` and a later read sees as `hidden`: a
    /// control is recorded only when both reads agree on it, since the person's window has its
    /// own width and moment. A sign-in control counts as absent only when a visitor was shown
    /// one the page lacks. Without a usable `hidden` read the person's page decides the
    /// sign-out control, and no sign-in control is recorded as absent.
    static func markers(person: PageProbe, hidden: PageProbe?, visitor: VisitorVerdict?) -> SessionMarkers {
        guard let hidden else {
            return SessionMarkers(signOutControlSeen: person.hasSignOutControl, signInControlAbsent: false)
        }
        return SessionMarkers(
            signOutControlSeen: person.hasSignOutControl && hidden.hasSignOutControl,
            signInControlAbsent: visitor == .showsSignInControl && !hidden.hasSignInControl
        )
    }

    /// The person says they are signed in: builds a grant that keeps the session and holds no
    /// secret. The page must pass the check `finish` makes (`signedInPage`); the start page and
    /// browse hosts are derived as `finish` derives them, and the only fill host is the
    /// sign-in host. A page with no evidence of a sign-in, or one a visitor sees the same way,
    /// is refused (`signInNotSeen`, `pageLooksPublic`) unless `confirming` is that refusal. A
    /// refusal leaves the enrollment as it was.
    ///
    /// The page is also read in hidden browsers, which can supply evidence of a sign-in or
    /// refuse the page (see the type's discussion). A save that finds the enrollment begun
    /// afresh or wiped while it ran is `cancelled`.
    func finishKeepingSession(
        name: String,
        confirming: Failure? = nil
    ) async throws -> (grant: SiteGrant, record: SiteRecord) {
        guard !isCancelled else { throw Failure.cancelled }
        guard keptSessionURL != nil, let broker else { throw Failure.notSignedIn }
        let generation = generation
        await idle()
        try ensureCurrent(generation)
        guard let signInURL = keptSessionURL else { throw Failure.notSignedIn }
        let page = try await signedInPage(broker: broker)
        try ensureCurrent(generation)
        noteCredentialPage(page.probe)
        let (grant, signInHost) = try await sessionGrant(
            signInURL: signInURL,
            page: page,
            sawSignIn: sawSignIn,
            confirming: confirming,
            generation: generation
        )

        let label = Proposal.displayText(name, limit: SiteRecord.nameLimit) ?? signInHost
        var record = SiteRecord(id: signInHost, name: label, added: Date(), lastSignedIn: Date())
        record.keepsSessionOnly = true
        if recordsCredentials {
            let result = capture.offer(siteHost: signInHost, browseHosts: grant.browseHosts)
            judgement = .keptSession(result, session: grant)
            logRefusal(of: result, siteHost: signInHost)
        }
        wipe()
        return (grant, record)
    }

    /// After an assisted sign-in for `stored`, a site's saved grant, whose filled password
    /// `finish` refused (`passwordNotFilled`, `passwordNotConfirmed`), judges the password the
    /// person typed into the page as a replacement for the saved one. Nothing is stored and
    /// nothing is wiped: the judgement is `passwordOffer` or `offerRefusal`, and
    /// `replacementGrant(for:)` builds on an offer.
    ///
    /// The page on display must be past the sign-in (`signedInPage`). With no password typed
    /// the judgement is `nothingTyped` and nothing more is read. A password typed on one of
    /// `stored`'s fill hosts replaces the saved one and nothing else, so it is judged without
    /// the refusals that concern a sign-in recorded afresh (`codeAsked`, `fieldUnidentified`;
    /// `CredentialCapture.replacementOffer`). One typed anywhere else is judged as
    /// `finishKeepingSession` judges it, against the grant that would keep the session on
    /// display, which needs the same hidden reads; `confirming` answers their refusal as it
    /// does there.
    ///
    /// Throws as `finishKeepingSession` does; `notSignedIn` also for an enrollment that records
    /// nothing or has no assisted sign-in under way. A refusal hands the page back to the app
    /// as `finish` does.
    func judgeTypedPassword(replacing stored: SiteGrant, confirming: Failure? = nil) async throws {
        guard !isCancelled else { throw Failure.cancelled }
        guard recordsCredentials, let pending, let broker else { throw Failure.notSignedIn }
        let generation = generation
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
        var judged = false
        var looksAgain = false
        defer {
            if !judged { rearm(lookingAgain: looksAgain) }
        }
        await idle()
        try ensureCurrent(generation)
        let page: (startURL: URL, startHost: String, probe: PageProbe)
        do {
            page = try await signedInPage(broker: broker)
        } catch Failure.notSignedIn {
            looksAgain = true
            throw Failure.notSignedIn
        }
        try ensureCurrent(generation)
        noteCredentialPage(page.probe)
        guard let signInHost = pending.signInURL.host(percentEncoded: false)?.lowercased() else {
            throw Failure.invalidGrant
        }

        if capture.password == nil {
            judgement = .newPassword(.failure(.nothingTyped), stored: stored)
        } else if capture.passwordTyped(onOneOf: stored.fillHosts) {
            let result = capture.replacementOffer(siteHost: signInHost, stored: stored)
            judgement = .newPassword(result, stored: stored)
            logRefusal(of: result, siteHost: signInHost)
        } else {
            let filledSignIn = session?.steps.isEmpty == false
            let (kept, _) = try await sessionGrant(
                signInURL: pending.signInURL,
                page: page,
                sawSignIn: sawSignIn || filledSignIn,
                confirming: confirming,
                generation: generation
            )
            let result = capture.offer(siteHost: signInHost, browseHosts: kept.browseHosts)
            judgement = .movedSignIn(result, session: kept, stored: stored)
            logRefusal(of: result, siteHost: signInHost)
        }
        judged = true
    }

    /// The grant that keeps the session on `page`, signed in to from `signInURL`, and its
    /// sign-in host. The start page and browse hosts are derived as `finish` derives them, and
    /// the only fill host is the sign-in host. The page is then read in hidden browsers (see
    /// the type's discussion), and refused (`signInNotSeen`, `pageLooksPublic`) unless
    /// `confirming` is that refusal; `sawSignIn` says a page of this enrollment asked for a
    /// sign-in. Throws `cancelled` when the enrollment is begun afresh, wiped, or cancelled
    /// after `generation`.
    private func sessionGrant(
        signInURL: URL,
        page: (startURL: URL, startHost: String, probe: PageProbe),
        sawSignIn: Bool,
        confirming: Failure?,
        generation: Int
    ) async throws -> (grant: SiteGrant, signInHost: String) {
        guard let signInHost = signInURL.host(percentEncoded: false)?.lowercased() else {
            throw Failure.invalidGrant
        }
        let browseHosts = browseHosts(required: [signInHost, page.startHost])

        let reads = await readSession(of: page, browseHosts: browseHosts)
        try ensureCurrent(generation)
        let markers = Self.markers(person: page.probe, hidden: reads.hidden, visitor: reads.visitor)
        let basis = try KeptSessionBasis.decide(
            sawSignIn: sawSignIn,
            showsSignOutControl: page.probe.hasSignOutControl,
            visitor: reads.visitor,
            confirming: confirming
        ).get()

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
            signOutControlSeen: markers.signOutControlSeen,
            signInControlAbsent: markers.signInControlAbsent,
            remembersPassword: false
        )
        guard grant.isValid(for: signInHost) else { throw Failure.invalidGrant }
        if basis == .personsWord, let confirming {
            AppLog.notice(.sites, "kept session taken on the person's word over \(confirming.caseName)")
        }
        return (grant, signInHost)
    }

    private func logRefusal(of result: Result<PasswordOffer, OfferRefusal>, siteHost: String) {
        if case let .failure(refusal) = result {
            AppLog.notice(.sites, "password offer withheld for \(siteHost): \(refusal.caseName)")
        }
    }

    /// A grant that signs in to the site by itself with the password the person typed: the
    /// offer the last successful `finishKeepingSession` made (`PasswordOffer.grant(upgrading:)`),
    /// built on `session`, the grant that save returned. Throws `invalidGrant` when there is no
    /// such offer, `session` is another grant, or the result is not a valid grant, and
    /// `cancelled` once the enrollment is.
    func passwordGrant(upgrading session: SiteGrant) throws -> SiteGrant {
        guard !isCancelled else { throw Failure.cancelled }
        guard case let .keptSession(.success(offer), judgedSession)? = judgement, judgedSession == session,
              let grant = offer.grant(upgrading: session)
        else { throw Failure.invalidGrant }
        return grant
    }

    /// The grant that replaces `stored` with the password the person typed, from the offer the
    /// last `judgeTypedPassword(replacing: stored)` made: `stored` with only its password
    /// swapped when it was typed on one of `stored`'s fill hosts
    /// (`PasswordOffer.grant(replacingPasswordOf:)`), and otherwise a grant built from the typed
    /// fields on the session on display, holding `stored`'s user name when none was typed
    /// (`PasswordOffer.grant(upgrading:usernameIfNoneTyped:)`). Throws `invalidGrant` when there
    /// is no such offer, it was judged for another grant, or the result is not a valid grant,
    /// and `cancelled` once the enrollment is.
    func replacementGrant(for stored: SiteGrant) throws -> SiteGrant {
        guard !isCancelled else { throw Failure.cancelled }
        let grant: SiteGrant?
        switch judgement {
        case let .newPassword(.success(offer), judgedStored)? where judgedStored == stored:
            grant = offer.grant(replacingPasswordOf: stored)
        case let .movedSignIn(.success(offer), session, judgedStored)? where judgedStored == stored:
            grant = offer.grant(upgrading: session, usernameIfNoneTyped: stored.username)
        default:
            grant = nil
        }
        guard let grant else { throw Failure.invalidGrant }
        return grant
    }

    /// Forgets what the person typed and the judgement of it, the offer included.
    func discardOffer() {
        forgetCredentials()
    }

    /// Ends the app's filling for good: no saved secret is filled into any page until the
    /// enrollment begins afresh. The secrets, what the person typed, and the judgement of it
    /// stay for the answer the person gives.
    func endFilling() {
        fillsEnded = true
        stopAssisting()
    }

    /// Hands the page of an assisted sign-in back to the app and has it look at the page again
    /// at once, unless the app's filling has ended (`endFilling`).
    func resumeFilling() {
        guard !isCancelled else { return }
        rearm(lookingAgain: true)
    }

    /// Ends the sign-in with no grant made: the app stops examining and filling pages for good,
    /// and forgets the secrets, what the person typed, and the judgement of it. The page stays
    /// on display; a later `finish` or `judgeTypedPassword(replacing:)` throws `notSignedIn`.
    func endSignIn() {
        fillsEnded = true
        stopAssisting()
        wipe()
        forgetCredentials()
        note = nil
    }

    /// Arms the app's work on the page of the assisted sign-in under way again, unless its
    /// filling has ended, asking it to look at the page at once when `lookingAgain`.
    private func rearm(lookingAgain: Bool) {
        guard pending != nil, !fillsEnded else { return }
        isArmed = true
        if lookingAgain { requestAssist() }
    }

    /// The app filled `step`. A password fill replaces whatever the person had typed into that
    /// field.
    private func appFilled(_ step: SignInStep) {
        guard step.kind == .password else { return }
        passwordTyped = false
        if recordsCredentials {
            capture.noteFilled(field: step.field, origin: step.origin, path: step.path)
        }
    }

    /// Calls `handler` once the enrollment ends: when it is cancelled, or, for one dropped
    /// without being cancelled, when it is freed. Called at once when it is already cancelled.
    func whenEnded(_ handler: @escaping @MainActor () -> Void) {
        guard !isCancelled else {
            handler()
            return
        }
        endHandlers.append(handler)
    }

    /// Throws `cancelled` when the enrollment has been cancelled, begun afresh, or wiped since
    /// `generation` was read.
    private func ensureCurrent(_ generation: Int) throws {
        guard !isCancelled, self.generation == generation else { throw Failure.cancelled }
    }

    /// What the hidden reads of a page found.
    private struct SessionReads: Sendable {
        /// What a later read shows, when it shows the start page past the sign-in.
        var hidden: PageProbe?
        /// What a visitor with no cookies gets, when the grant records no sign-out control and
        /// the check can be made.
        var visitor: VisitorVerdict?
    }

    /// Reads the start page as a later read would, then, when the grant will record no sign-out
    /// control, as a visitor would, comparing like with like. The enrollment counts as working
    /// while the reads run, and cancelling it ends them.
    private func readSession(
        of page: (startURL: URL, startHost: String, probe: PageProbe),
        browseHosts: Set<String>
    ) async -> SessionReads {
        let (dataStore, pages, visitorPages, settling) = (dataStore, simulatedPages, visitorPages, settling)
        let (checksVisitor, recheckDelay) = (checksVisitor, visitorRecheckDelay)
        let reading = Task { @MainActor in
            var reads = SessionReads()
            reads.hidden = await HiddenRead.startPage(
                page.startURL,
                browseHosts: browseHosts,
                dataStore: dataStore,
                pages: pages,
                settling: settling
            )
            let provisional = Self.markers(person: page.probe, hidden: reads.hidden, visitor: nil)
            guard checksVisitor, !provisional.signOutControlSeen, !Task.isCancelled else { return reads }
            reads.visitor = await VisitorCheck.run(
                startURL: page.startURL,
                browseHosts: browseHosts,
                signedIn: reads.hidden ?? page.probe,
                pages: visitorPages,
                settling: settling,
                recheckDelay: recheckDelay
            )
            return reads
        }
        sessionReadTask = reading
        isReadingSession = true
        refreshWorking()
        defer {
            sessionReadTask = nil
            isReadingSession = false
            refreshWorking()
        }
        return await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
    }

    /// The page on display, read afresh, when it shows the user signed in: an `https` page on
    /// a valid host, done loading, with no password field, no field or row of boxes that asks
    /// for a code, and no large sign-in frame. Returns it as a start page, without its query
    /// and fragment.
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
        sessionReadTask?.cancel()
        stopAssisting()
        wipe()
        forgetCredentials()
        browser.close()
        let handlers = endHandlers
        endHandlers = []
        handlers.forEach { $0() }
    }

    /// Returns once the app has finished examining the pages loaded so far.
    func idle() async {
        while let task = assistTask ?? observeTask {
            await task.value
        }
    }

    // MARK: Examining pages

    private func wipe() {
        generation += 1
        stopObserving()
        sawSignIn = false
        if appearsSignedIn { appearsSignedIn = false }
        isArmed = false
        assistRequested = false
        pending = nil
        keptSessionURL = nil
        session = nil
        broker = nil
        capture.wipe()
    }

    /// Forgets what the person typed and the judgement of it.
    private func forgetCredentials() {
        capture.wipe()
        judgement = nil
    }

    /// Lets the capture take a look at a probe of the page on display.
    private func noteCredentialPage(_ page: PageProbe) {
        guard recordsCredentials, isSigningIn else { return }
        capture.notePage(page)
    }

    private func stopAssisting() {
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
    }

    private func pageFinished() {
        if isArmed { requestAssist() }
        if observesPages { requestObservation(settling: true) }
    }

    // MARK: Watching the page

    private func stopObserving() {
        observeRequested = false
        observeSettles = false
        observeTask?.cancel()
        recheckTask?.cancel()
        recheckTask = nil
    }

    /// Whether the timed re-probe of the page is running.
    var isRechecking: Bool { recheckTask != nil }

    /// Probes the page every `recheckInterval` while it is observed (`observesPages`), skipping
    /// a turn while a load is in flight, whose finish is probed anyway. The task holds the
    /// enrollment only between its sleeps, so it never keeps one alive, and ends once the page
    /// is no longer observed.
    private func startRechecking() {
        recheckTask?.cancel()
        let interval = recheckInterval
        recheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard self.observesPages else {
                    self.recheckTask = nil
                    return
                }
                if !self.browser.webView.isLoading {
                    self.requestObservation(settling: false)
                }
            }
        }
    }

    /// Asks for the open page of a sign-in to be probed, once the page in
    /// flight, if any, has been. A request made while one runs is met by one more probe.
    /// `settling` waits for the page to finish loading and hold still first, which a page
    /// that has just loaded needs and a page the person is typing into does not.
    private func requestObservation(settling: Bool) {
        observeRequested = true
        if settling { observeSettles = true }
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            while let self, self.observesPages, self.observeRequested, !Task.isCancelled {
                self.observeRequested = false
                let settles = self.observeSettles
                self.observeSettles = false
                await self.observeCurrentPage(settling: settles)
            }
            guard let self else { return }
            self.observeTask = nil
            // A request that arrived while a cancelled task was winding down found the task
            // still in place and started none.
            if self.observeRequested, self.observesPages {
                self.requestObservation(settling: false)
            }
        }
    }

    /// Notes whether the page on display asks for a sign-in (`SignInRules.asksForSignIn`), and
    /// whether it looks signed in (`appearsSignedIn`). Only the noting is kept, never what the
    /// page holds.
    private func observeCurrentPage(settling: Bool) async {
        guard let broker, observesPages else { return }
        if settling {
            do {
                try await browser.settleLoadedPage()
            } catch {
                return
            }
        }
        guard !Task.isCancelled, observesPages,
              let probe = try? await broker.probe(),
              !Task.isCancelled, observesPages
        else { return }
        noteCredentialPage(probe)
        if SignInRules.asksForSignIn(probe) {
            sawSignIn = true
        }
        let looksSignedIn = probe.isSecureTopFrame
            && SignInRules.isPastSignIn(probe)
            && (sawSignIn || probe.hasSignOutControl)
        if looksSignedIn != appearsSignedIn { appearsSignedIn = looksSignedIn }
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
            guard let self else { return }
            self.assistTask = nil
            // A request that arrived while a cancelled task was winding down found the task
            // still in place and started none.
            if self.isArmed, self.assistRequested {
                self.requestAssist()
            }
            self.refreshWorking()
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
        isWorking = isBeginning || assistTask != nil || isReadingSession
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
