import Combine
import Foundation

/// The sign-in window's state, for a site the person is asked to sign in to: a site ProVisor
/// asked for that is not granted, or a granted site kept by its session. The person signs in on
/// the page and presses Done, and the session is saved as the site's grant, holding no secret.
/// The window's view only lays this out.
///
/// **The page opens by itself only at an address the app can vouch for** (`Start.decide`): a
/// granted site's own sign-in address, or a requested host the person's own browsers have
/// visited (`BrowsingHistory`). The agent's request is model output shaped by mail from anyone,
/// so any other host it names is only named in a sentence, and the address field starts empty
/// for the person to type the address themselves.
///
/// Done saves through `SiteAccessCenter.save`, which is what settles a request for the site and
/// owes the pass that was waiting on it; this model starts nothing else.
@MainActor
final class SiteSignInModel: ObservableObject {
    /// How the window starts.
    enum Start: Equatable {
        /// The page opens at this address as the window appears.
        case opensPage(URL)
        /// The person types the address; `host` is the one asked for, named in a sentence only.
        case asksForAddress(host: String)

        /// Where a sign-in to `host` starts. The page opens by itself only at an address the
        /// Keychain or the person's own browsing vouches for: the saved sign-in address of a
        /// granted site whose grant keeps a session, or `https://<host>` for a host that is not
        /// granted, is a plain host name, and that `hasVisited` finds in the history.
        /// `hasVisited` is asked only about such a host.
        ///
        /// A granted site with no readable grant, or one that keeps a saved password, asks for
        /// the address: its record comes from `sites.json`, which anything running as the user
        /// can edit. The window never shows either (`ProVisorSiteWindow.opening`).
        @MainActor
        static func decide(
            host: String,
            record: SiteRecord?,
            grant: SiteGrant?,
            hasVisited: (String) -> Bool
        ) -> Start {
            if record != nil {
                guard let grant, !grant.remembersPassword else { return .asksForAddress(host: host) }
                return .opensPage(grant.signInURL)
            }
            guard let url = trustedAddress(host), hasVisited(host) else {
                return .asksForAddress(host: host)
            }
            return .opensPage(url)
        }

        /// `https://<host>`, for a plain host name.
        @MainActor
        private static func trustedAddress(_ host: String) -> URL? {
            guard SiteHost.isValid(host) else { return nil }
            return SiteEnrollment.normalisedAddress(host)
        }
    }

    enum DoneOutcome: Equatable {
        case notSaved
        case saved
    }

    /// The granted site a save would be stored as, if any.
    enum Destination: Equatable {
        case newSite
        /// A site kept by its session; the save keeps its name and `added` date.
        case keptSession(SiteRecord)
        /// A site whose grant keeps a saved password, or whose grant cannot be read while its
        /// record does not say it keeps a session only. A session saved over it would discard
        /// the password.
        case savedPassword

        /// Where a save as `siteID` lands among `sites`, judged by the stored grant first.
        static func of(
            _ siteID: String,
            sites: [SiteRecord],
            grant: (String) -> SiteGrant?
        ) -> Destination {
            guard let record = sites.first(where: { $0.id == siteID }) else { return .newSite }
            if let stored = grant(siteID) {
                return stored.remembersPassword ? .savedPassword : .keptSession(record)
            }
            return record.keepsSessionOnly ? .keptSession(record) : .savedPassword
        }
    }

    static let recognisedRequestMessage = "ProVisor asked for this site. It matches a site in your browser history."

    static func unrecognisedRequestMessage(host: String) -> String {
        "ProVisor asked for \(host). SuperVisor hasn't seen that address in your browser history, so type the site's address yourself."
    }

    static func needsSignInMessage(name: String) -> String {
        "\(name) needs you to sign in again."
    }

    static let instruction = "Sign in on the page, then press Done."

    /// The site asked for: a granted site's id, or the host a request named.
    let host: String
    /// The proposal that asked for the site, if any.
    let proposalID: String?
    let start: Start
    let title: String
    /// Why the person is asked, or nil when they asked themselves.
    let sentence: String?
    /// The sentence names a host the app cannot vouch for.
    let sentenceIsCaution: Bool

    /// The address field, shown only when the window asks for the address.
    @Published var address = ""
    @Published private(set) var problem: SiteSaveProblem?
    /// True while a page is being opened or the sign-in saved.
    @Published private(set) var isWorking = false
    /// Whether a page has been opened for the person to sign in on.
    @Published private(set) var hasOpenedPage = false

    /// The granted site's record, whose name a new sign-in is given.
    private let record: SiteRecord?
    /// The address the page was last opened at.
    private var openedAddress: String?
    /// The grant and record `finishKeepingSession` returned, kept until they are stored so a
    /// failed save can be tried again without signing in again.
    private var finished: (grant: SiteGrant, record: SiteRecord)?

    /// `record` is the granted site's record, nil for a host that is not granted. `needsPerson`
    /// says the site is flagged as needing the person or a run was turned away from it.
    init(host: String, record: SiteRecord?, start: Start, proposalID: String?, needsPerson: Bool) {
        self.host = host
        self.record = record
        self.start = start
        self.proposalID = proposalID
        if let record {
            title = "Sign in to \(record.name)"
            if needsPerson {
                sentence = Self.needsSignInMessage(name: record.name)
            } else if proposalID != nil {
                sentence = SiteFormModel.signInAgainRequestMessage(name: record.name)
            } else {
                sentence = nil
            }
            sentenceIsCaution = false
        } else {
            switch start {
            case .opensPage:
                title = "Sign in to \(host)"
                sentence = proposalID == nil ? nil : Self.recognisedRequestMessage
                sentenceIsCaution = false
            case let .asksForAddress(asked):
                title = "Sign in"
                sentence = Self.unrecognisedRequestMessage(host: asked)
                sentenceIsCaution = true
            }
        }
    }

    var asksForAddress: Bool {
        if case .asksForAddress = start { return true }
        return false
    }

    /// Open Page, beside the address field.
    var canOpenTypedAddress: Bool {
        asksForAddress && !isWorking && SiteEnrollment.normalisedAddress(address) != nil
    }

    /// The sentence beside the address field, once something that is not an address is typed.
    var addressProblem: String? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, SiteEnrollment.normalisedAddress(typed) == nil else { return nil }
        return SiteSaveProblem.invalidAddress.message
    }

    /// Done can always be pressed once a page is open, except while a page opens or a save runs.
    var canPressDone: Bool {
        hasOpenedPage && !isWorking
    }

    /// Whether the page that opened by itself failed to load, which Try Again answers.
    var offersRetry: Bool {
        problem == .pageDidNotLoad && !asksForAddress && !isWorking
    }

    /// Whether the last Done was refused for want of a sign-in the app saw, or because the page
    /// reads the same to a visitor, which the person may answer by saving on their own word.
    var offersSaveAnyway: Bool {
        problem?.allowsSavingAnyway == true && canPressDone
    }

    /// The name the site is saved under: a granted site keeps its own, and a new one is named
    /// after the address its page was opened at.
    var siteName: String {
        if let record { return record.name }
        return SiteFormModel.suggestedName(forAddress: openedAddress ?? host)
    }

    // MARK: Opening the page

    /// Opens the page as the window appears, when the start is an address the app vouches for.
    func beginIfTrusted(using enrollment: SiteEnrollment) async {
        guard case let .opensPage(url) = start, !hasOpenedPage else { return }
        await openPage(url.absoluteString, using: enrollment)
    }

    /// Opens the trusted address again, after a load that did not finish.
    func retry(using enrollment: SiteEnrollment) async {
        guard case let .opensPage(url) = start else { return }
        await openPage(url.absoluteString, using: enrollment)
    }

    /// Opens the address the person typed. A request's site is answered only by a site saved
    /// under the requested host; a sign-in to any other address is saved as that site and
    /// leaves the request open.
    func openTypedAddress(using enrollment: SiteEnrollment) async {
        guard canOpenTypedAddress, let url = SiteEnrollment.normalisedAddress(address) else { return }
        await openPage(url.absoluteString, using: enrollment)
    }

    private func openPage(_ address: String, using enrollment: SiteEnrollment) async {
        guard !isWorking else { return }
        problem = nil
        finished = nil
        openedAddress = address
        hasOpenedPage = true
        isWorking = true
        defer { isWorking = false }
        do {
            try await enrollment.beginKeepingSession(signInAddress: address)
        } catch SiteEnrollment.Failure.cancelled {
            // The window that showed this enrollment has closed or moved on.
            return
        } catch {
            let problem = SiteSaveProblem.ofSignIn(error)
            self.problem = problem
            // A refused address leaves nothing for Done to build on.
            if problem == .invalidAddress {
                hasOpenedPage = false
                openedAddress = nil
            }
        }
    }

    // MARK: Done

    /// Builds the grant from the page the person is on and stores it. Nothing is stored once
    /// the enrollment has been cancelled, however far the save had got.
    ///
    /// The site the save lands on is looked up afresh, since the person may have typed the
    /// address of any granted site (`Destination`): a site with a saved password is refused,
    /// and a site kept by its session keeps its name and the date it was added.
    ///
    /// `confirmingSignIn` is the person's answer to the refusal the window shows, a Done refused
    /// for want of a sign-in the app saw or because the page cannot be told from a visitor's. It
    /// answers that refusal alone and counts only while the window shows it.
    func done(
        using enrollment: SiteEnrollment,
        into center: SiteAccessCenter,
        confirmingSignIn: Bool = false
    ) async -> DoneOutcome {
        guard canPressDone else { return .notSaved }
        let confirming = confirmingSignIn && offersSaveAnyway ? problem?.confirmation : nil
        isWorking = true
        defer { isWorking = false }
        problem = nil

        var result: (grant: SiteGrant, record: SiteRecord)
        if let finished {
            result = finished
        } else {
            do {
                result = try await enrollment.finishKeepingSession(
                    name: siteName,
                    confirming: confirming
                )
            } catch {
                problem = SiteSaveProblem.ofFinish(error)
                return .notSaved
            }
            finished = result
        }

        guard !enrollment.isCancelled else { return .notSaved }
        switch Destination.of(result.record.id, sites: center.access.sites(), grant: center.storedGrant) {
        case .newSite:
            break
        case let .keptSession(existing):
            result.record.name = existing.name
            result.record.added = existing.added
        case .savedPassword:
            problem = .hasSavedPassword
            return .notSaved
        }
        do {
            try center.save(grant: result.grant, record: result.record)
        } catch {
            problem = .notSaved
            return .notSaved
        }
        finished = nil
        return .saved
    }
}
