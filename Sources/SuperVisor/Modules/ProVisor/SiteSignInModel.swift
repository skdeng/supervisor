import Combine
import Foundation

/// The sign-in window's state, for a site the person is asked to sign in to: a site ProVisor
/// asked for that is not granted, or a granted site. For a site that is not granted, or one
/// kept by its session, the person signs in on the page and presses Done, and the session is
/// saved as the site's grant, holding no secret. The window's view only lays this out.
///
/// **The page opens by itself** (`Start.decide`): at a granted site's own sign-in address, or
/// at `https://<host>` for a host a request named. The agent's request is model output shaped
/// by mail from anyone, and only the Keychain or the person's own browsing vouches for an
/// address (`BrowsingHistory`). A requested host the browsers do not know opens with a
/// cautioning sentence that names it for the person to check, and the window records nothing
/// typed there (`Start.opensUnrecognisedPage`).
///
/// Done saves through `SiteAccessCenter.save`, or records a sign-in through
/// `SiteAccessCenter.personSignedIn`, which is what settles a request for the site and owes the
/// pass that was waiting on it; this model starts nothing else.
///
/// **A site with a saved password is signed in to through the saved grant's own request**
/// (`Start.fillsSavedPassword`, `SiteFormModel.SignInRequest(saved:)`): the app fills the saved
/// secrets while the person watches, the user name and password only on the hosts the grant
/// fills on, and the person finishes in the page what the app cannot. A site that turned the
/// saved password away (`SiteRecord.passwordRejected`) has it withheld
/// (`Start.withholdsSavedPassword`): the person types the password, and Done goes straight to
/// case 2. Done ends one of three ways, and never stores a grant that keeps the session alone
/// over the saved password:
///
/// 1. The enrollment confirms the saved password took (`SiteEnrollment.finish`): the refreshed
///    grant is stored under the site's own name and `added` date, and the window closes.
/// 2. It does not, and the password the person typed can be kept
///    (`SiteEnrollment.judgeTypedPassword(replacing:)`): nothing is stored yet, the app fills
///    nothing more in this window, and the panel asks whether to keep the typed password in
///    place of the saved one (`keepTypedPassword`), with follow-up passes held as for any
///    offer. Typed on one of the grant's fill hosts, it replaces the saved password and nothing
///    else. Leave As Is, closing the window, and an offer left unanswered for `offerTimeout`
///    each end as case 3.
/// 3. Otherwise the stored grant stays exactly as it is, and the person's sign-in is recorded
///    once a hidden read confirms the stored grant is signed in
///    (`SiteAccessCenter.personSignedIn`), with whether the app's fill of the saved password
///    worked here; when it did not, the app asks the person at the next lapse instead of
///    submitting it. The panel says which, after why a typed password was not kept when one
///    was typed. A sign-in that cannot be confirmed records nothing and leaves Done to press
///    again.
///
/// **A window may offer to keep the password the person typed** (`recordsCredentials`): only
/// when the setting allows it and the page opened by itself at an address the app vouches for.
/// A window that asks for the address, or that opened a host the person's browsers do not
/// know, never records and never offers. A window that may offer is given an
/// enrollment that records (`SiteEnrollment.recordingCredentials`); Done saves the session as
/// any window does, then, if the setting still allows it, shows the enrollment's offer or,
/// unless nothing was typed, why there is none (`panel`), and the window stays open until the
/// person answers. Keep Password stores a grant that signs in by itself (`keepPassword`). Every
/// other way out ends the enrollment, which forgets what was typed, and leaves the session as
/// saved; so does an offer left unanswered for `offerTimeout`. Whenever no offer is shown, the
/// enrollment's judgement of what was typed is discarded at once.
///
/// While an offer shows, follow-up passes are held back (`FollowUpHolding`), since keeping the
/// password saves the site again and a save closes the visits open on it; the hold lasts until
/// the enrollment ends. A refusal is followed by no second save, so it holds nothing.
@MainActor
final class SiteSignInModel: ObservableObject {
    /// How the window starts.
    enum Start: Equatable {
        /// The page opens as the window appears, at an address the Keychain or the person's
        /// own browsing vouches for.
        case opensPage(URL)
        /// The page opens as the window appears, at the address of a requested host the
        /// person's browsers do not know. The window cautions the person to check the address.
        case opensUnrecognisedPage(URL)
        /// The person types the address; `host` is the one asked for, named in a sentence only.
        case asksForAddress(host: String)
        /// The page opens at the saved sign-in address of a granted site whose grant keeps a
        /// saved password, and the app fills the grant's saved secrets while the person watches.
        case fillsSavedPassword(SiteGrant)
        /// As `fillsSavedPassword`, for a site that turned the saved password away
        /// (`SiteRecord.passwordRejected`): the app fills the rest and leaves the password field
        /// to the person.
        case withholdsSavedPassword(SiteGrant)

        /// The grant a start with a saved password fills from.
        var savedGrant: SiteGrant? {
            switch self {
            case let .fillsSavedPassword(grant), let .withholdsSavedPassword(grant): grant
            case .opensPage, .opensUnrecognisedPage, .asksForAddress: nil
            }
        }

        /// Where a sign-in to `host` starts. A granted site opens at its saved sign-in address;
        /// one whose grant keeps a saved password fills it, unless the record says the site
        /// turned it away. A host that is not granted and is a plain host name opens at
        /// `https://<host>`, vouched for when `hasVisited` finds it in the history and
        /// unrecognised otherwise. `hasVisited` is asked only about such a host.
        ///
        /// A granted site with no readable grant asks for the address: its record comes from
        /// `sites.json`, which anything running as the user can edit. The window never shows it
        /// (`ProVisorSiteWindow.opening`).
        @MainActor
        static func decide(
            host: String,
            record: SiteRecord?,
            grant: SiteGrant?,
            hasVisited: (String) -> Bool
        ) -> Start {
            if let record {
                guard let grant else { return .asksForAddress(host: host) }
                guard grant.remembersPassword else { return .opensPage(grant.signInURL) }
                return record.passwordRejected ? .withholdsSavedPassword(grant) : .fillsSavedPassword(grant)
            }
            guard let url = address(ofHost: host) else { return .asksForAddress(host: host) }
            return hasVisited(host) ? .opensPage(url) : .opensUnrecognisedPage(url)
        }

        /// `https://<host>`, for a plain host name.
        @MainActor
        private static func address(ofHost host: String) -> URL? {
            guard SiteHost.isValid(host) else { return nil }
            return SiteEnrollment.normalisedAddress(host)
        }
    }

    enum DoneOutcome: Equatable {
        case notSaved
        /// Saved, and nothing more to ask: the window closes.
        case saved
        /// Saved, and the panel asks about the password: the window stays open.
        case savedAndAsking
        /// Nothing saved yet; the panel asks whether to keep the typed password in place of the
        /// saved one, and the window stays open.
        case asking
        /// The saved password was kept as it was and the person's sign-in recorded; the panel
        /// says so, and the window stays open.
        case signedInKeepingSavedPassword
    }

    enum KeepOutcome: Equatable {
        case notKept
        case kept
    }

    /// What replaces the lower part of the window once the session is saved.
    enum Panel: Equatable {
        /// Asks whether to keep the password, showing the user name as typed (nil when none
        /// was) and the host the password was typed on. The password itself is never shown.
        case offer(siteName: String, username: String?, host: String)
        /// Says why no password is offered.
        case refused(OfferRefusal)
        /// Asks whether to keep the password the person typed in place of the saved one the app
        /// could not use, showing what `offer` shows.
        case replacement(siteName: String, username: String?, host: String)
        /// Says the person's sign-in was recorded and the saved password kept as it was, after
        /// why the password the person typed was not kept, when one was typed.
        case savedPasswordKept(OfferRefusal?)
        /// As `savedPasswordKept`, when the saved password was not seen to work in this window:
        /// the app will ask the person again instead of submitting it.
        case savedPasswordTurnedAway(OfferRefusal?)

        /// The panel for what the enrollment's save found, or nil when there is nothing to say:
        /// no offer, and no password typed.
        static func of(offer: PasswordOffer?, refusal: OfferRefusal?, siteName: String) -> Panel? {
            if let offer {
                return .offer(siteName: siteName, username: offer.usernameText, host: offer.passwordHost)
            }
            guard let refusal, refusal != .nothingTyped else { return nil }
            return .refused(refusal)
        }
    }

    /// The granted site a save would be stored as, if any.
    enum Destination: Equatable {
        case newSite
        /// A site kept by its session; the save keeps its name and `added` date.
        case keptSession(SiteRecord)
        /// The site with a saved password the window was opened for, which only a grant that
        /// keeps a password may replace; the save keeps its name and `added` date.
        case ownSavedPassword(SiteRecord)
        /// A site whose grant keeps a saved password, or whose grant cannot be read while its
        /// record does not say it keeps a session only, and that the window was not opened for.
        /// A session saved over it would discard the password.
        case savedPassword

        /// Where a save as `siteID` lands among `sites`, judged by the stored grant first.
        /// `savedPasswordSite` is the site with a saved password the window was opened for.
        static func of(
            _ siteID: String,
            sites: [SiteRecord],
            grant: (String) -> SiteGrant?,
            savedPasswordSite: String? = nil
        ) -> Destination {
            guard let record = sites.first(where: { $0.id == siteID }) else { return .newSite }
            if let stored = grant(siteID) {
                guard stored.remembersPassword else { return .keptSession(record) }
                return siteID == savedPasswordSite ? .ownSavedPassword(record) : .savedPassword
            }
            return record.keepsSessionOnly ? .keptSession(record) : .savedPassword
        }
    }

    static let recognisedRequestMessage = "ProVisor asked for this site. It matches a site in your browser history."

    static func unrecognisedRequestMessage(host: String) -> String {
        "ProVisor asked for \(host). SuperVisor hasn't seen that address in your browser history, so check it is the site you expect before you sign in."
    }

    static func unopenableRequestMessage(host: String) -> String {
        "ProVisor asked for \(host). SuperVisor can't open that address by itself, so type the site's address yourself."
    }

    static func needsSignInMessage(name: String) -> String {
        "\(name) needs you to sign in again."
    }

    static func savedPasswordMessage(name: String) -> String {
        "\(name) needs you to sign in again. SuperVisor fills what it has saved; finish anything it can't."
    }

    static let replacementQuestion = "SuperVisor couldn't use the saved password. Keep the one you typed instead?"

    static func rejectedPasswordMessage(name: String, offersToKeep: Bool) -> String {
        offersToKeep
            ? "\(name) didn't accept the saved password. Sign in on the page; SuperVisor can keep the password you type."
            : "\(name) didn't accept the saved password. Sign in on the page."
    }

    static let savedPasswordKeptMessage = "You're signed in. SuperVisor kept the saved password as it was; if it can't sign in by itself next time, it will ask you again."

    static let savedPasswordTurnedAwayMessage = "You're signed in. The saved password wasn't accepted, so SuperVisor will ask you again when this session ends."

    static let instruction = "Sign in on the page, then press Done."

    static let recordingCaption = "SuperVisor can offer to keep the password you type here."

    static func offerQuestion(siteName: String) -> String {
        "Keep your password in the Keychain so SuperVisor can sign in to \(siteName) by itself?"
    }

    static let noUsernameTyped = "No user name typed"

    /// Whether a window that starts at `start` records what the person types: only when the
    /// setting allows it and the page opens by itself at an address the app vouches for.
    static func recordsCredentials(start: Start, offersPasswords: Bool) -> Bool {
        guard offersPasswords else { return false }
        switch start {
        case .opensPage, .fillsSavedPassword, .withholdsSavedPassword: return true
        case .opensUnrecognisedPage, .asksForAddress: return false
        }
    }

    /// The enrollment's note as the window shows it: nil for the notes that name a Save button
    /// this window does not have, whose part the instruction beneath plays.
    static func windowNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let namingSave = [
            SiteEnrollment.Notes.signInYourself,
            SiteEnrollment.Notes.finishYourself,
            SiteEnrollment.Notes.checkAndSave,
        ]
        return namingSave.contains(note) ? nil : note
    }

    /// What to say when a saved secret was not filled on a host the grant does not fill on.
    static func movedMessage(_ fill: AssistedSignInSession.UnvettedFill) -> String {
        switch fill.kind {
        case .code:
            "This site's sign-in page has moved to \(fill.host), where SuperVisor doesn't fill your saved key. Type the code in the page to continue."
        case .username, .password:
            "This site's sign-in page has moved to \(fill.host), where SuperVisor doesn't fill your saved password. Type it in the page to continue."
        }
    }

    /// The site asked for: a granted site's id, or the host a request named.
    let host: String
    /// The proposal that asked for the site, if any.
    let proposalID: String?
    let start: Start
    let title: String
    /// Why the person is asked, or nil when they asked themselves.
    let sentence: String?
    /// The sentence names a host neither the Keychain nor the person's browsing vouches for.
    let sentenceIsCaution: Bool
    /// Whether the window records what the person types and may offer to keep the password.
    let recordsCredentials: Bool

    /// The address field, shown only when the window asks for the address.
    @Published var address = ""
    @Published private(set) var problem: SiteSaveProblem?
    /// True while a page is being opened or the sign-in saved.
    @Published private(set) var isWorking = false
    /// Whether a page has been opened for the person to sign in on.
    @Published private(set) var hasOpenedPage = false
    /// Shown after Done in place of Done: once a session is saved, or once a site with a saved
    /// password has an answer to give or a question to ask; nil before, and when there is
    /// nothing to say.
    @Published private(set) var panel: Panel?

    /// The granted site's record, whose name a new sign-in is given.
    private let record: SiteRecord?
    /// The address the page was last opened at.
    private var openedAddress: String?
    /// The grant and record `SiteEnrollment.finishKeepingSession`, or for a site with a saved
    /// password `SiteEnrollment.finish`, returned, kept until they are stored so a failed save
    /// can be tried again without signing in again.
    private var finished: (grant: SiteGrant, record: SiteRecord)?
    /// The session grant and record Done stored, which Keep Password builds on.
    private var savedSession: (grant: SiteGrant, record: SiteRecord)?
    /// Set once the offer to replace the saved password has its answer, whichever it was.
    private var replacementAnswered = false
    /// Counts the offers to replace the saved password shown, so a handler left by an earlier
    /// one acts on nothing.
    private var replacementCount = 0
    /// The hold the offer to replace the saved password takes.
    private var replacementHold: FollowUpHolds.Token?
    private let followUps: any FollowUpHolding
    private let offerTimeout: Duration
    /// The wait for an answer to the offer on screen.
    private var offerExpiry: Task<Void, Never>?

    /// How long an offer waits for an answer before it ends as Session Only, or for an offer to
    /// replace a saved password, as Leave As Is.
    static let standardOfferTimeout: Duration = .seconds(300)

    /// `record` is the granted site's record, nil for a host that is not granted. `needsPerson`
    /// says the site is flagged as needing the person or a run was turned away from it.
    /// `offersPasswords` is the setting that allows an offer, and `followUps` what an offer on
    /// screen holds back.
    init(
        host: String,
        record: SiteRecord?,
        start: Start,
        proposalID: String?,
        needsPerson: Bool,
        offersPasswords: Bool,
        followUps: any FollowUpHolding,
        offerTimeout: Duration = SiteSignInModel.standardOfferTimeout
    ) {
        self.host = host
        self.record = record
        self.start = start
        self.proposalID = proposalID
        self.followUps = followUps
        self.offerTimeout = offerTimeout
        recordsCredentials = Self.recordsCredentials(start: start, offersPasswords: offersPasswords)
        if let record {
            title = "Sign in to \(record.name)"
            if case .fillsSavedPassword = start {
                sentence = Self.savedPasswordMessage(name: record.name)
            } else if case .withholdsSavedPassword = start {
                sentence = Self.rejectedPasswordMessage(name: record.name, offersToKeep: recordsCredentials)
            } else if needsPerson {
                sentence = Self.needsSignInMessage(name: record.name)
            } else if proposalID != nil {
                sentence = SiteFormModel.signInAgainRequestMessage(name: record.name)
            } else {
                sentence = nil
            }
            sentenceIsCaution = false
        } else {
            switch start {
            case .opensPage, .fillsSavedPassword, .withholdsSavedPassword:
                title = "Sign in to \(host)"
                sentence = proposalID == nil ? nil : Self.recognisedRequestMessage
                sentenceIsCaution = false
            case .opensUnrecognisedPage:
                title = "Sign in to \(host)"
                sentence = Self.unrecognisedRequestMessage(host: host)
                sentenceIsCaution = true
            case let .asksForAddress(asked):
                title = "Sign in"
                sentence = Self.unopenableRequestMessage(host: asked)
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

    /// Done can always be pressed once a page is open, except while a page opens or a save
    /// runs, and once the panel shows. The app signing in with saved secrets does not hold it
    /// back: pressing it ends that work, a wait for a code or a fill in flight included, and a
    /// Done refused because the page still asks for a sign-in has the app look at the page
    /// again at once (`SiteEnrollment.finish`).
    var canPressDone: Bool {
        hasOpenedPage && !isWorking && panel == nil
    }

    /// Whether the page that opened by itself failed to load, which Try Again answers.
    var offersRetry: Bool {
        problem == .pageDidNotLoad && !asksForAddress && !isWorking
    }

    /// Whether a site with a saved password reads its codes from texts, which the window
    /// explains while texts are off or cannot be read.
    var readsTextedCodes: Bool {
        start.savedGrant?.codeKind == .text
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

    /// Opens the page as the window appears, when the start names an address to open.
    func openStartPage(using enrollment: SiteEnrollment) async {
        guard !hasOpenedPage else { return }
        await retry(using: enrollment)
    }

    /// Opens the start's address again, after a load that did not finish.
    func retry(using enrollment: SiteEnrollment) async {
        switch start {
        case let .opensPage(url), let .opensUnrecognisedPage(url):
            await openPage(url.absoluteString, using: enrollment)
        case let .fillsSavedPassword(grant):
            await signIn(with: SiteFormModel.SignInRequest(saved: grant), using: enrollment)
        case let .withholdsSavedPassword(grant):
            await signIn(with: SiteFormModel.SignInRequest(savedWithholdingPassword: grant), using: enrollment)
        case .asksForAddress:
            return
        }
    }

    /// Opens the saved sign-in address and fills what `request` carries, through the request
    /// the Sign In Again form shares (`SiteFormModel.SignInRequest.begin(on:)`). The model does
    /// not count as working while the app signs in, so Done stays open to a person who
    /// finishes by hand.
    private func signIn(with request: SiteFormModel.SignInRequest, using enrollment: SiteEnrollment) async {
        guard !isWorking else { return }
        problem = nil
        finished = nil
        openedAddress = request.address
        hasOpenedPage = true
        do {
            try await request.begin(on: enrollment)
        } catch SiteEnrollment.Failure.cancelled {
            return
        } catch {
            let problem = SiteSaveProblem.ofSignIn(error)
            self.problem = problem
            if problem == .invalidAddress {
                hasOpenedPage = false
                openedAddress = nil
            }
        }
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
        if start.savedGrant != nil {
            let confirming = confirmingSignIn && offersSaveAnyway ? problem?.confirmation : nil
            return await doneWithSavedPassword(using: enrollment, into: center, confirming: confirming)
        }
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
        case .savedPassword, .ownSavedPassword:
            problem = .hasSavedPassword
            return .notSaved
        }

        // The setting is read again here, so turning it off while the window is open stops an
        // offer that has not been shown.
        let panel = recordsCredentials && enrollment.recordsCredentials && center.offersPasswords
            ? Panel.of(offer: enrollment.passwordOffer, refusal: enrollment.offerRefusal, siteName: result.record.name)
            : nil
        let offers = if case .offer = panel { true } else { false }
        // The hold is taken before the save, which is what owes a follow-up pass.
        let hold = offers ? holdFollowUps(until: enrollment) : nil
        do {
            try center.save(grant: result.grant, record: result.record)
        } catch {
            if let hold { followUps.releaseFollowUps(hold) }
            problem = .notSaved
            return .notSaved
        }
        finished = nil
        if !offers { enrollment.discardOffer() }
        guard let panel else { return .saved }
        savedSession = result
        self.panel = panel
        if offers { expireOffer(after: offerTimeout, ending: enrollment) }
        return .savedAndAsking
    }

    /// Ends `enrollment` as Session Only does once `timeout` passes with the offer unanswered.
    /// The wait is called off when the enrollment ends any other way.
    private func expireOffer(after timeout: Duration, ending enrollment: SiteEnrollment) {
        offerExpiry?.cancel()
        let expiry = Task { [weak self, weak enrollment] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, case .offer = self.panel, let enrollment, !enrollment.isCancelled
            else { return }
            AppLog.notice(.sites, "password offer unanswered for \(self.host); kept the session only")
            enrollment.cancel()
        }
        offerExpiry = expiry
        enrollment.whenEnded { expiry.cancel() }
    }

    // MARK: Keeping the password

    /// Keep Password: stores a grant that signs in by itself with the password the person
    /// typed (`SiteEnrollment.passwordGrant(upgrading:)`) in place of the session Done saved.
    /// It stores nothing unless the panel offers the password, the enrollment is live, and the
    /// site is still the kept session Done saved; a refusal or a failed save shows `notSaved`
    /// and leaves the panel and the session as they were.
    func keepPassword(using enrollment: SiteEnrollment, into center: SiteAccessCenter) -> KeepOutcome {
        guard case .offer = panel, let savedSession, !isWorking, !enrollment.isCancelled else {
            return .notKept
        }
        problem = nil
        guard case let .keptSession(existing) = Destination.of(
            savedSession.record.id,
            sites: center.access.sites(),
            grant: center.storedGrant
        ),
            let grant = try? enrollment.passwordGrant(upgrading: savedSession.grant)
        else {
            problem = .notSaved
            return .notKept
        }
        var record = savedSession.record
        record.name = existing.name
        record.added = existing.added
        record.keepsSessionOnly = false
        do {
            try center.save(grant: grant, record: record)
        } catch {
            problem = .notSaved
            return .notKept
        }
        offerExpiry?.cancel()
        offerExpiry = nil
        AppLog.notice(.sites, "password kept for \(record.id)")
        return .kept
    }

    // MARK: A site with a saved password

    /// Done for a site with a saved password (see the type's discussion for the three ways it
    /// ends). With the password withheld it goes straight to what the person typed. A refusal
    /// that a further sign-in on the page can put right, such as a page still asking for a
    /// sign-in, shows as `problem` with Done open again. `confirming` answers the refusal on
    /// screen, as the kept session's Save Anyway does.
    private func doneWithSavedPassword(
        using enrollment: SiteEnrollment,
        into center: SiteAccessCenter,
        confirming: SiteEnrollment.Failure?
    ) async -> DoneOutcome {
        guard canPressDone, let saved = start.savedGrant else { return .notSaved }
        isWorking = true
        defer { isWorking = false }
        problem = nil

        if case .withholdsSavedPassword = start {
            return await afterSavedPasswordUnused(saved, using: enrollment, into: center, confirming: confirming)
        }
        var result: (grant: SiteGrant, record: SiteRecord)
        if let finished {
            result = finished
        } else {
            do {
                result = try await enrollment.finish(name: siteName)
            } catch SiteEnrollment.Failure.passwordNotFilled, SiteEnrollment.Failure.passwordNotConfirmed {
                return await afterSavedPasswordUnused(saved, using: enrollment, into: center, confirming: confirming)
            } catch {
                problem = SiteSaveProblem.ofFinish(error)
                return .notSaved
            }
            finished = result
        }

        guard !enrollment.isCancelled else { return .notSaved }
        switch Destination.of(result.record.id, sites: center.access.sites(), grant: center.storedGrant, savedPasswordSite: host) {
        case .newSite:
            break
        case let .keptSession(existing), let .ownSavedPassword(existing):
            result.record.name = existing.name
            result.record.added = existing.added
        case .savedPassword:
            problem = .hasSavedPassword
            return .notSaved
        }
        guard result.grant.remembersPassword else {
            problem = .notSaved
            return .notSaved
        }
        do {
            try center.save(grant: result.grant, record: result.record)
        } catch {
            problem = .notSaved
            return .notSaved
        }
        finished = nil
        AppLog.notice(.sites, "saved password confirmed for \(result.record.id)")
        return .saved
    }

    /// The saved password did not take, the app filled none, or it was withheld. When the window
    /// records what the person typed and the setting still allows it, a typed password is judged
    /// as a replacement (`SiteEnrollment.judgeTypedPassword(replacing:)`) and offered; otherwise
    /// the person's sign-in is recorded with the stored grant kept. A judgement refused for the
    /// page, such as one still asking for a sign-in or one a visitor sees the same way, shows as
    /// `problem` and keeps what was typed for the next Done.
    private func afterSavedPasswordUnused(
        _ saved: SiteGrant,
        using enrollment: SiteEnrollment,
        into center: SiteAccessCenter,
        confirming: SiteEnrollment.Failure?
    ) async -> DoneOutcome {
        var refusal: OfferRefusal?
        if recordsCredentials, enrollment.recordsCredentials, center.offersPasswords {
            do {
                try await enrollment.judgeTypedPassword(replacing: saved, confirming: confirming)
                if let offer = enrollment.passwordOffer, center.offersPasswords {
                    showReplacement(
                        username: enrollment.replacementUsername,
                        host: offer.passwordHost,
                        using: enrollment,
                        into: center
                    )
                    return .asking
                }
                refusal = enrollment.offerRefusal
            } catch SiteEnrollment.Failure.cancelled {
                return .notSaved
            } catch {
                problem = SiteSaveProblem.ofFinish(error) ?? .notSignedIn
                return .notSaved
            }
        }
        return await recordSignInKeepingSavedPassword(
            refusal: refusal,
            using: enrollment,
            into: center,
            resumesFillingWhenUnconfirmed: true
        )
    }

    /// Whether the stored password is believed good after this window: only when the app's own
    /// fill of it was accepted here.
    private func storedPasswordWorked(in enrollment: SiteEnrollment) -> Bool {
        if case .withholdsSavedPassword = start { return false }
        return enrollment.filledPasswordWasAccepted
    }

    /// Shows the offer to keep the typed password in place of the saved one, ending the app's
    /// filling for the rest of the window and holding follow-up passes until the enrollment
    /// ends. Closing the window with the offer unanswered ends as Leave As Is does.
    private func showReplacement(
        username: String?,
        host typedOn: String,
        using enrollment: SiteEnrollment,
        into center: SiteAccessCenter
    ) {
        enrollment.endFilling()
        replacementAnswered = false
        replacementCount += 1
        replacementHold = holdFollowUps(until: enrollment)
        panel = .replacement(siteName: siteName, username: username, host: typedOn)
        let (siteID, shown, worked) = (host, replacementCount, storedPasswordWorked(in: enrollment))
        // The model is held until the enrollment ends, which may be after the window let it go.
        enrollment.whenEnded { [self, center] in
            guard replacementCount == shown, case .replacement = panel, !replacementAnswered else { return }
            replacementAnswered = true
            AppLog.notice(.sites, "typed password offer closed for \(siteID); kept the saved one")
            recordingAfterClose = Task {
                _ = await center.personSignedIn(siteID: siteID, storedPasswordWorked: worked)
            }
        }
        expireReplacement(after: offerTimeout, ending: enrollment, into: center)
    }

    /// The recording of the person's sign-in that closing the window on an unanswered offer to
    /// replace the saved password set off; nil when none was.
    private(set) var recordingAfterClose: Task<Void, Never>?

    /// Answers the offer on screen as Leave As Is once `timeout` passes unanswered, then ends
    /// `enrollment`. The wait is called off when the enrollment ends any other way.
    private func expireReplacement(after timeout: Duration, ending enrollment: SiteEnrollment, into center: SiteAccessCenter) {
        offerExpiry?.cancel()
        let expiry = Task { [weak self, weak enrollment] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let enrollment, !enrollment.isCancelled,
                  case .replacement = self.panel, !self.replacementAnswered
            else { return }
            AppLog.notice(.sites, "typed password offer unanswered for \(self.host); kept the saved one")
            // Leave As Is calls off the wait on screen, which is this task.
            self.offerExpiry = nil
            _ = await self.leaveAsIs(using: enrollment, into: center)
            enrollment.cancel()
        }
        offerExpiry = expiry
        enrollment.whenEnded { expiry.cancel() }
    }

    /// Keep Typed Password: stores the grant that replaces the saved one with the password the
    /// person typed (`SiteEnrollment.replacementGrant(for:)`). It stores nothing unless the panel
    /// offers it unanswered, the enrollment is live, and the site still holds the grant the
    /// window was opened with; a refusal or a failed save shows `notSaved` and leaves the panel
    /// and the stored grant as they were. The save goes through `SiteAccess.add`, which clears
    /// `SiteRecord.passwordRejected`.
    func keepTypedPassword(using enrollment: SiteEnrollment, into center: SiteAccessCenter) -> KeepOutcome {
        guard case .replacement = panel, let saved = start.savedGrant, !replacementAnswered, !isWorking,
              !enrollment.isCancelled
        else { return .notKept }
        problem = nil
        guard case let .ownSavedPassword(existing) = Destination.of(
            host,
            sites: center.access.sites(),
            grant: center.storedGrant,
            savedPasswordSite: host
        ),
            center.storedGrant(for: host) == saved,
            let grant = try? enrollment.replacementGrant(for: saved),
            grant.remembersPassword
        else {
            problem = .notSaved
            return .notKept
        }
        do {
            try center.save(grant: grant, record: existing)
        } catch {
            problem = .notSaved
            return .notKept
        }
        replacementAnswered = true
        offerExpiry?.cancel()
        offerExpiry = nil
        AppLog.notice(.sites, "typed password kept in place of the saved one for \(host)")
        return .kept
    }

    /// Leave As Is: the stored grant stays as it is and the person's sign-in is recorded
    /// (`recordSignInKeepingSavedPassword`). The hold on follow-up passes is lifted, since
    /// nothing more will be saved. A sign-in that cannot be confirmed takes the panel away and
    /// leaves Done to press again, with the app's filling still ended.
    func leaveAsIs(using enrollment: SiteEnrollment, into center: SiteAccessCenter) async -> DoneOutcome {
        guard case .replacement = panel, !replacementAnswered, !isWorking, !enrollment.isCancelled else {
            return .notSaved
        }
        replacementAnswered = true
        offerExpiry?.cancel()
        offerExpiry = nil
        isWorking = true
        defer { isWorking = false }
        let outcome = await recordSignInKeepingSavedPassword(
            refusal: nil,
            using: enrollment,
            into: center,
            resumesFillingWhenUnconfirmed: false
        )
        if let replacementHold {
            followUps.releaseFollowUps(replacementHold)
            self.replacementHold = nil
        }
        if outcome != .signedInKeepingSavedPassword {
            panel = nil
        }
        return outcome
    }

    /// Records the person's sign-in with the stored grant kept (`SiteAccessCenter.personSignedIn`),
    /// saying whether the stored password worked here, and ends the enrollment's sign-in, so
    /// nothing more is filled; the panel then says so, after `refusal`'s sentence. A sign-in the
    /// hidden read does not confirm records nothing and shows `signInNotConfirmed`, handing the
    /// page back to the app when `resumesFillingWhenUnconfirmed`. What the person typed is
    /// forgotten either way.
    private func recordSignInKeepingSavedPassword(
        refusal: OfferRefusal?,
        using enrollment: SiteEnrollment,
        into center: SiteAccessCenter,
        resumesFillingWhenUnconfirmed: Bool
    ) async -> DoneOutcome {
        let worked = storedPasswordWorked(in: enrollment)
        enrollment.discardOffer()
        guard !enrollment.isCancelled else { return .notSaved }
        guard await center.personSignedIn(siteID: host, storedPasswordWorked: worked) != nil else {
            problem = .signInNotConfirmed
            if resumesFillingWhenUnconfirmed { enrollment.resumeFilling() }
            return .notSaved
        }
        enrollment.endSignIn()
        let shown = refusal == .nothingTyped ? nil : refusal
        panel = worked ? .savedPasswordKept(shown) : .savedPasswordTurnedAway(shown)
        return .signedInKeepingSavedPassword
    }

    /// Holds follow-up passes back until `enrollment` ends, however it ends.
    private func holdFollowUps(until enrollment: SiteEnrollment) -> FollowUpHolds.Token {
        let token = followUps.holdFollowUps()
        enrollment.whenEnded { [followUps] in
            followUps.releaseFollowUps(token)
        }
        return token
    }
}

/// A model for a site with a saved password holds its grant, so no reflection of it shows it.
extension SiteSignInModel: CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: []) }
}
