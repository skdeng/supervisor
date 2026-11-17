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
@MainActor
final class SiteEnrollment: ObservableObject {
    enum Failure: Error, Equatable {
        /// The address is not an `https` address on a valid host with no port or credentials.
        case invalidAddress
        /// The page is not one that shows the user signed in.
        case notSignedIn
        /// What was observed does not make a valid grant.
        case invalidGrant
    }

    /// What the app says about where it stands.
    enum Notes {
        static let signingIn = "Signing in for you."
        static let finishYourself = "Finish signing in in the page, then save the site."
        static let checkAndSave = "If the page shows you are signed in, save the site."
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
    private var session: AssistedSignInSession?
    private var broker: SignInBroker?
    private var isBeginning = false
    private var isArmed = false
    private var assistTask: Task<Void, Never>?
    private var assistRequested = false
    /// The hosts navigations went through up to the first page past the sign-in, once there.
    private var hostsAtSignIn: Set<String>?

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
            settling: settling
        )
        browser.navigationObserver = { [weak self] in
            self?.refreshLocation()
        }
        browser.pageFinishedObserver = { [weak self] in
            self?.pageFinished()
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
    func begin(
        signInAddress: String,
        username: String,
        password: String,
        authenticatorKey: String?,
        codeKind: SiteGrant.CodeKind,
        codeSender: String?
    ) async throws {
        guard let url = Self.normalisedAddress(signInAddress) else { throw Failure.invalidAddress }
        stopAssisting()
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
            codes: codes
        )
        hostsAtSignIn = nil
        learnedCodeSender = nil
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

    /// The user says they are signed in: builds the grant from what was observed.
    ///
    /// The page is read afresh, and must be an `https` page on a valid host that shows no
    /// password field, no field that asks for a code, and no large sign-in frame. The start
    /// page is that page without its query and fragment; the browse hosts are the hosts the
    /// sign-in went through; the fill hosts are the sign-in host and the hosts the filled pages
    /// and forms belong to. A refusal leaves the enrollment as it was.
    func finish(name: String) async throws -> (grant: SiteGrant, record: SiteRecord) {
        guard let pending, let session, let broker else { throw Failure.notSignedIn }
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
        await idle()
        var succeeded = false
        defer {
            if !succeeded, self.pending != nil { isArmed = true }
        }

        guard !browser.webView.isLoading,
              let current = browser.currentURL,
              current.scheme?.lowercased() == "https",
              current.port == nil,
              let currentComponents = URLComponents(url: current, resolvingAgainstBaseURL: false),
              currentComponents.user == nil,
              currentComponents.password == nil,
              let startHost = current.host(percentEncoded: false)?.lowercased(),
              SiteHost.isValid(startHost),
              let probe = try? await broker.probe(),
              probe.isSecureTopFrame,
              SignInRules.isPastSignIn(probe)
        else { throw Failure.notSignedIn }

        var startComponents = currentComponents
        startComponents.query = nil
        startComponents.fragment = nil
        guard let startURL = startComponents.url,
              let signInHost = pending.signInURL.host(percentEncoded: false)?.lowercased()
        else { throw Failure.invalidGrant }

        let steps = session.steps
        var fillHosts = [signInHost]
        for host in steps.map({ String($0.origin.dropFirst("https://".count)) }) + session.submissionHosts
        where !fillHosts.contains(host) {
            fillHosts.append(host)
        }
        guard fillHosts.allSatisfy(SiteHost.isValid) else { throw Failure.invalidGrant }

        let required = Set(fillHosts).union([signInHost, startHost])
        var browseHosts = required
        let observed = (hostsAtSignIn ?? browser.traversedHosts.union(browser.visitedHosts))
            .filter(SiteHost.isValid)
        if required.union(observed).count <= SiteGrant.maximumHosts {
            browseHosts.formUnion(observed)
        }

        let codeSender: String? = switch pending.codeKind {
        case .text: session.learnedCodeSender ?? pending.codeSender
        case .email: pending.codeSender
        case .none, .authenticator: nil
        }
        let grant = SiteGrant(
            username: pending.username,
            password: pending.password,
            authenticatorKey: pending.codeKind == .authenticator ? pending.authenticatorKey : nil,
            signInURL: pending.signInURL,
            startURL: startURL,
            fillHosts: fillHosts,
            browseHosts: [signInHost] + browseHosts.subtracting([signInHost]).sorted(),
            codeKind: pending.codeKind,
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

    /// Stops examining pages, forgets the secrets, and closes the browser. The enrollment is
    /// finished with.
    func cancel() {
        stopAssisting()
        wipe()
        browser.close()
    }

    /// Returns once the app has finished examining the pages loaded so far.
    func idle() async {
        while let task = assistTask {
            await task.value
        }
    }

    // MARK: Examining pages

    private func wipe() {
        isArmed = false
        assistRequested = false
        pending = nil
        session = nil
        broker = nil
    }

    private func stopAssisting() {
        isArmed = false
        assistRequested = false
        assistTask?.cancel()
    }

    private func pageFinished() {
        guard isArmed else { return }
        requestAssist()
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
        let url = browser.currentURL
        currentHost = url?.host(percentEncoded: false)?.lowercased()
        currentIsSecure = url?.scheme?.lowercased() == "https" && browser.webView.hasOnlySecureContent
    }
}
