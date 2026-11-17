import Foundation
import Testing

@testable import SuperVisor

/// A proposal's `site` is the agent's word, shaped by mail from anyone, so what is under test is
/// that only a plain host gets through, that it offers a sign-in and decides nothing, and that
/// only saving the site settles the request.
@Suite("ProVisor site requests")
@MainActor
struct SiteRequestTests {
    private let modified = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ fields: [String: Any], id: String = "2026-11-17-check") -> Proposal? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return Proposal.parse(data, id: id, modified: modified)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-requests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let request: [String: Any] = [
        "title": "Confirm the renewal on your Example Club account",
        "why": "The receipt names no card.",
        "options": [["label": "It's fine", "action": "Record that in followups/x.md."]],
        "kind": "confirm",
        "site": "example.com",
    ]

    // MARK: Parsing

    @Test("A site is read lowercased")
    func siteIsLowercased() {
        var fields = request
        fields["site"] = "My.Example.COM"
        #expect(parse(fields)?.site == "my.example.com")
        #expect(parse(request)?.site == "example.com")
    }

    @Test(
        "A site that is not a plain host drops the field and keeps the proposal",
        arguments: [
            "https://example.com",
            "example.com/login",
            "example.com:443",
            "user@example.com",
            "example",
            "127.0.0.1",
            "exa mple.com",
            "example.com.",
            "\u{212A}ayak.com",
            "xn--80ak6aa92e.com\u{202E}",
            "",
            String(repeating: "a.", count: 130) + "com",
        ]
    )
    func invalidSiteIsDropped(_ value: String) throws {
        var fields = request
        fields["site"] = value
        let proposal = try #require(parse(fields))
        #expect(proposal.site == nil)
        #expect(proposal.title == "Confirm the renewal on your Example Club account")
    }

    @Test("A site that is not text drops the field, and a proposal without one has none")
    func nonTextSite() throws {
        var fields = request
        fields["site"] = ["example.com"]
        #expect(try #require(parse(fields)).site == nil)
        fields["site"] = nil
        #expect(try #require(parse(fields)).site == nil)
    }

    @Test("A raised item carries its site into the queue")
    func raisedItemCarriesSite() throws {
        #expect(RaisedItems.carriedFields.contains("site"))
        let workspace = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let raised = workspace.appendingPathComponent("raised", isDirectory: true)
        let proposals = workspace.appendingPathComponent("proposals", isDirectory: true)
        for directory in [raised, proposals] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try JSONSerialization.data(withJSONObject: request).write(to: raised.appendingPathComponent("a.json"))

        let admitted = RaisedItems.admit(from: raised, into: proposals, now: modified) { "0a1b2c3d" }

        #expect(admitted == 1)
        #expect(ProposalStore.load(from: proposals).first?.site == "example.com")
    }

    @Test("A changed site makes the reviewed text stale")
    func siteIsReviewedText() throws {
        let first = try #require(parse(request))
        var fields = request
        fields["site"] = "other.example"
        let second = try #require(parse(fields))
        #expect(ReviewedText(first) != ReviewedText(second))
        #expect(ReviewedText(first).site == "example.com")
    }

    // MARK: The button

    @Test("The button names the host, or the granted site by its name")
    func buttonTitle() {
        let granted = SiteRecord(id: "example.com", name: "Example Club", added: modified)
        #expect(ProposalReview.siteButtonTitle(host: "example.com", grantedSites: []) == "Sign In to example.com…")
        #expect(ProposalReview.siteButtonTitle(host: "example.com", grantedSites: [granted]) == "Sign In Again to Example Club…")
        #expect(ProposalReview.siteButtonTitle(host: "other.example", grantedSites: [granted]) == "Sign In to other.example…")
    }

    // MARK: Settling

    /// A proposals folder holding the request, as written by the agent.
    private func folder(with fields: [String: Any]) throws -> (directory: URL, file: URL) {
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("2026-11-17-check.json")
        try JSONSerialization.data(withJSONObject: fields).write(to: file)
        return (directory, file)
    }

    private func settle(
        in directory: URL,
        host: String = "example.com",
        savedSiteID: String = "example.com",
        isBusy: Bool = false
    ) -> SiteRequests.Outcome {
        SiteRequests.settle(
            proposalID: "2026-11-17-check",
            host: host,
            savedSiteID: savedSiteID,
            siteName: "Example Club",
            in: directory,
            isBusy: isBusy,
            now: Date(timeIntervalSince1970: 1_794_936_720),  // 2026-11-17T17:32:00Z
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
    }

    @Test("Saving the site the request asked for records it done with the site's name, and no choice")
    func settleRecordsDone() throws {
        let (directory, file) = try folder(with: request)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(settle(in: directory) == .settled)

        let loaded = try #require(ProposalStore.load(from: directory).first)
        #expect(loaded.status == .done)
        #expect(loaded.result == "Signed in to Example Club.")
        #expect(loaded.decided == Date(timeIntervalSince1970: 1_794_936_720))
        #expect(loaded.choice == nil)
        #expect(loaded.site == "example.com")
        let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(fields["chose"] == nil)
        #expect(fields["instructed"] == nil)
        #expect(fields["automatic"] == nil)
        #expect(fields["decidedLocal"] as? String == "Tuesday 2026-11-17 09:32")
    }

    @Test("A failed request settles, and a site written in another case still matches")
    func settleFailedAndCased() throws {
        var fields = request
        fields["status"] = "failed"
        fields["site"] = "Example.COM"
        let (directory, _) = try folder(with: fields)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(settle(in: directory) == .settled)
        #expect(ProposalStore.load(from: directory).first?.status == .done)
    }

    @Test("A request dismissed on disk is left alone, whatever a copy in memory says")
    func settleRefusesDismissedOnDisk() throws {
        let (directory, file) = try folder(with: request)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The copy the review window holds still awaits a decision.
        #expect(try #require(ProposalStore.load(from: directory).first).isOpen)
        try ProposalStore.record(id: "2026-11-17-check", in: directory, status: .dismissed)
        let before = try Data(contentsOf: file)

        #expect(settle(in: directory) == .notOpen)
        #expect(try Data(contentsOf: file) == before)

        for status in ["done", "withdrawn", "nonsense"] {
            var fields = request
            fields["status"] = status
            try JSONSerialization.data(withJSONObject: fields).write(to: file)
            let unchanged = try Data(contentsOf: file)
            #expect(settle(in: directory) == .notOpen, "\(status)")
            #expect(try Data(contentsOf: file) == unchanged)
        }
    }

    @Test("A request whose site was rewritten or removed on disk is left alone")
    func settleRefusesChangedSite() throws {
        for site: Any? in ["other.example", nil, "https://example.com", 7] {
            var fields = request
            fields["site"] = site
            let (directory, file) = try folder(with: fields)
            defer { try? FileManager.default.removeItem(at: directory) }
            let before = try Data(contentsOf: file)

            #expect(settle(in: directory) == .siteChanged, "\(String(describing: site))")
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test("Saving a site other than the one asked for leaves the request alone")
    func settleRefusesOtherSite() throws {
        let (directory, file) = try folder(with: request)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: file)

        #expect(settle(in: directory, savedSiteID: "login.example.com") == .otherSite)
        #expect(settle(in: directory, host: "other.example", savedSiteID: "other.example") == .siteChanged)
        #expect(settle(in: directory, isBusy: true) == .busy)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("A request whose file is gone is not recorded")
    func settleMissingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(settle(in: directory) == .notRecorded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    // MARK: One request per site

    private func proposal(
        _ id: String,
        site: String?,
        createdAgo: TimeInterval,
        status: Proposal.Status = .proposed,
        expiresIn: TimeInterval? = nil
    ) -> Proposal {
        Proposal(
            id: id,
            title: id,
            why: nil,
            options: [ProposalOption(label: "Suggested", action: "a")],
            kind: "confirm",
            created: modified.addingTimeInterval(-createdAgo),
            expires: expiresIn.map { modified.addingTimeInterval($0) },
            status: status,
            result: nil,
            isCleared: false,
            site: site
        )
    }

    @Test("Of several open requests for one site, only the earliest is shown, and others are unaffected")
    func oneRequestPerSite() {
        let proposals = [
            proposal("b-later", site: "example.com", createdAgo: 60),
            proposal("a-first", site: "example.com", createdAgo: 600),
            proposal("c-other-site", site: "other.example", createdAgo: 30),
            proposal("d-no-site", site: nil, createdAgo: 10),
            proposal("e-no-site", site: nil, createdAgo: 20),
        ]

        let visible = ProposalQueue.visible(proposals, now: modified).map(\.id)

        #expect(visible == ["d-no-site", "e-no-site", "c-other-site", "a-first"])
        #expect(ProposalQueue.repeatedSiteRequests(in: proposals, now: modified) == ["b-later"])
    }

    @Test("Two requests for one site created together are told apart by id")
    func tieByID() {
        let proposals = [
            proposal("z-request", site: "example.com", createdAgo: 60),
            proposal("m-request", site: "example.com", createdAgo: 60),
        ]

        #expect(ProposalQueue.visible(proposals, now: modified).map(\.id) == ["m-request"])
    }

    @Test("A settled or expired request does not hide a later open one")
    func settledRequestDoesNotHide() {
        let proposals = [
            proposal("a-done", site: "example.com", createdAgo: 900, status: .done),
            proposal("b-dismissed", site: "example.com", createdAgo: 800, status: .dismissed),
            proposal("c-expired", site: "example.com", createdAgo: 700, expiresIn: -1),
            proposal("d-open", site: "example.com", createdAgo: 60),
        ]

        let visible = ProposalQueue.visible(proposals, now: modified).map(\.id)

        #expect(visible == ["d-open", "a-done"])
        #expect(ProposalQueue.repeatedSiteRequests(in: proposals, now: modified).isEmpty)
    }

    @Test("A repeated request for a site is not announced")
    func repeatedRequestIsNotAnnounced() {
        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [proposal("a-first", site: "example.com", createdAgo: 600)])

        let added = announcer.countNew(
            in: [
                proposal("a-first", site: "example.com", createdAgo: 600),
                proposal("b-again", site: "example.com", createdAgo: 60),
                proposal("c-other", site: "other.example", createdAgo: 60),
            ],
            automatic: [],
            now: modified
        )

        #expect(added == 1)
    }

    @Test("A request a sign-in prompt announces is not counted as a new idea, and is seen all the same")
    func coveredRequestIsNotCounted() {
        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [])
        let loaded = [
            proposal("a-request", site: "example.com", createdAgo: 60),
            proposal("b-idea", site: nil, createdAgo: 60),
        ]

        #expect(announcer.countNew(in: loaded, automatic: [], covered: ["a-request"], now: modified) == 1)
        // Once seen it is never counted, whether or not a prompt still covers it.
        #expect(announcer.countNew(in: loaded, automatic: [], covered: [], now: modified) == 0)
    }

    @Test("A request no prompt covers, such as one for a host never visited, counts as a new idea")
    func uncoveredRequestIsCounted() {
        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [])
        let loaded = [proposal("a-request", site: "stranger.example", createdAgo: 60)]

        #expect(announcer.countNew(in: loaded, automatic: [], covered: [], now: modified) == 1)
    }

    @Test("A request awaiting recognition is held back, then counted as an idea when its host is not recognised")
    func heldBackRequestBecomesAnIdea() {
        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [])
        let loaded = [
            proposal("a-request", site: "stranger.example", createdAgo: 60),
            proposal("b-idea", site: nil, createdAgo: 60),
        ]

        #expect(announcer.countNew(in: loaded, automatic: [], awaitingRecognition: ["a-request"], now: modified) == 1)
        // Still awaiting: nothing is released, and a later count leaves it held back.
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: ["a-request"], now: modified) == 0)
        #expect(announcer.countNew(in: loaded, automatic: [], awaitingRecognition: ["a-request"], now: modified) == 0)

        // Not recognised: no prompt covers it, so it is an idea, counted once.
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: [], now: modified) == 1)
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: [], now: modified) == 0)
        #expect(announcer.countNew(in: loaded, automatic: [], covered: [], now: modified) == 0)
    }

    @Test("A request awaiting recognition is held back, then never counted when its host is recognised")
    func heldBackRequestBecomesASignIn() {
        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [])
        let loaded = [proposal("a-request", site: "known.example", createdAgo: 60)]

        #expect(announcer.countNew(in: loaded, automatic: [], awaitingRecognition: ["a-request"], now: modified) == 0)
        // Recognised: the sign-in prompt covers it, and it is seen without being counted.
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: ["a-request"], awaitingRecognition: [], now: modified) == 0)
        #expect(announcer.countNew(in: loaded, automatic: [], covered: [], now: modified) == 0)
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: [], now: modified) == 0)
    }

    @Test("A held-back request that resolved before the next count is counted by that count")
    func heldBackRequestResolvedByTheNextCount() {
        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [])
        let loaded = [proposal("a-request", site: "stranger.example", createdAgo: 60)]

        #expect(announcer.countNew(in: loaded, automatic: [], awaitingRecognition: ["a-request"], now: modified) == 0)
        #expect(announcer.countNew(in: loaded, automatic: [], covered: [], now: modified) == 1)
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: [], now: modified) == 0)
    }

    @Test("Nothing is released before the announcer is seeded, and a held-back request no longer on file is forgotten")
    func releaseNeedsSeedAndFile() {
        var unseeded = ProposalAnnouncer()
        let loaded = [proposal("a-request", site: "stranger.example", createdAgo: 60)]
        #expect(unseeded.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: [], now: modified) == 0)

        var announcer = ProposalAnnouncer()
        announcer.seedIfNeeded(with: [])
        _ = announcer.countNew(in: loaded, automatic: [], awaitingRecognition: ["a-request"], now: modified)
        #expect(announcer.countReleased(in: [], automatic: [], covered: [], awaitingRecognition: [], now: modified) == 0)
        #expect(announcer.countReleased(in: loaded, automatic: [], covered: [], awaitingRecognition: [], now: modified) == 0)
    }

    // MARK: The window

    private func item(
        _ kind: SignInDemand.Item.Kind,
        proposalID: String? = nil
    ) -> SignInDemand.Item {
        SignInDemand.Item(host: "example.com", displayName: "Example", kind: kind, proposalID: proposalID)
    }

    @Test("A site kept by its session opens the sign-in window, carrying the request that asked for it")
    func routeForSessionSite() {
        #expect(ProVisorSiteWindow.route(for: item(.signedOut(keepsSession: true), proposalID: "check"))
            == .signingIn(host: "example.com", requestedBy: "check"))
        #expect(ProVisorSiteWindow.route(for: item(.signedOut(keepsSession: true)))
            == .signingIn(host: "example.com", requestedBy: nil))
    }

    @Test("A site with a saved password opens the sign-in window too, carrying the request that asked for it")
    func routeForPasswordSite() {
        #expect(ProVisorSiteWindow.route(for: item(.signedOut(keepsSession: false), proposalID: "check"))
            == .signingIn(host: "example.com", requestedBy: "check"))
        #expect(ProVisorSiteWindow.route(for: item(.signedOut(keepsSession: false)))
            == .signingIn(host: "example.com", requestedBy: nil))
    }

    @Test("A requested host opens the sign-in window for its request, and one with no proposal opens nothing")
    func routeForRequestedHost() {
        for recognised in [true, false] {
            #expect(ProVisorSiteWindow.route(for: item(.requested(recognised: recognised), proposalID: "ask"))
                == .signingIn(host: "example.com", requestedBy: "ask"))
        }
        #expect(ProVisorSiteWindow.route(for: item(.requested(recognised: true))) == nil)
    }

    @Test("Settings and the review window route a granted site, however it is kept, and a new host to the sign-in window")
    func routeFromSettingsAndReview() {
        var session = SiteRecord(id: "example.com", name: "Bank", added: Date(timeIntervalSince1970: 0))
        session.keepsSessionOnly = true
        let password = SiteRecord(id: "club.example", name: "Club", added: Date(timeIntervalSince1970: 0))

        #expect(ProVisorSiteWindow.route(forSite: session, requestedBy: nil)
            == .signingIn(host: "example.com", requestedBy: nil))
        #expect(ProVisorSiteWindow.route(forSite: password, requestedBy: nil)
            == .signingIn(host: "club.example", requestedBy: nil))

        let granted = [session, password]
        #expect(ProVisorSiteWindow.route(forRequestedHost: "example.com", proposalID: "p", grantedSites: granted)
            == .signingIn(host: "example.com", requestedBy: "p"))
        #expect(ProVisorSiteWindow.route(forRequestedHost: "club.example", proposalID: "p", grantedSites: granted)
            == .signingIn(host: "club.example", requestedBy: "p"))
        #expect(ProVisorSiteWindow.route(forRequestedHost: "new.example", proposalID: "p", grantedSites: granted)
            == .signingIn(host: "new.example", requestedBy: "p"))
    }

    private func grant(remembersPassword: Bool) -> SiteGrant {
        SiteGrant(
            username: remembersPassword ? "alice@example.com" : "",
            password: remembersPassword ? "saved-password" : "",
            authenticatorKey: nil,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil,
            remembersPassword: remembersPassword
        )
    }

    @Test("A readable grant opens the sign-in window, whether it keeps a saved password or a session")
    func openingFollowsTheGrant() {
        let record = SiteRecord(id: "example.com", name: "Bank", added: Date(timeIntervalSince1970: 0))
        let password = grant(remembersPassword: true)
        let session = grant(remembersPassword: false)
        typealias Window = ProVisorSiteWindow

        for route in [Window.SignInRoute.signingIn(host: "example.com", requestedBy: "p"),
                      .signingInAgain(siteID: "example.com", requestedBy: "p")] {
            for stored in [password, session] {
                #expect(Window.opening(for: route, record: record, grant: stored)
                    == .signIn(host: "example.com", requestedBy: "p"))
            }
        }
    }

    @Test("A granted site whose stored sign-in cannot be read opens the Add Site form, keeping its request, whichever way it is kept")
    func openingUnreadableGrant() {
        var session = SiteRecord(id: "example.com", name: "Bank", added: Date(timeIntervalSince1970: 0))
        session.keepsSessionOnly = true
        let password = SiteRecord(id: "example.com", name: "Bank", added: Date(timeIntervalSince1970: 0))
        typealias Window = ProVisorSiteWindow

        for record in [session, password] {
            for proposalID in ["p", nil] as [String?] {
                #expect(Window.opening(for: .signingIn(host: "example.com", requestedBy: proposalID), record: record, grant: nil)
                    == .unreadable(record: record, requestedBy: proposalID))
                #expect(Window.opening(for: .signingInAgain(siteID: "example.com", requestedBy: proposalID), record: record, grant: nil)
                    == .unreadable(record: record, requestedBy: proposalID))
            }
        }
        let form = SiteFormModel(unreadableSite: session, requestedBy: "p")
        #expect(form.address.isEmpty)
        #expect(!form.canOpenPage)
        #expect(form.notice == "Bank's saved sign-in couldn't be read. Add it again.")
        #expect(form.request?.proposalID == "p")
    }

    @Test("A site whose record is gone opens as a new site, keeping the request that asked for it")
    func openingRemovedSite() {
        typealias Window = ProVisorSiteWindow
        for route in [Window.SignInRoute.signingIn(host: "example.com", requestedBy: "2026-11-17-check"),
                      .signingInAgain(siteID: "example.com", requestedBy: "2026-11-17-check")] {
            #expect(Window.opening(for: route, record: nil, grant: nil)
                == .signIn(host: "example.com", requestedBy: "2026-11-17-check"))
        }
        for route in [Window.SignInRoute.signingIn(host: "example.com", requestedBy: nil),
                      .signingInAgain(siteID: "example.com", requestedBy: nil)] {
            #expect(Window.opening(for: route, record: nil, grant: nil) == .addingSite)
        }
    }

    @Test("The window reuses its form only for the same mode and the same request, and its sign-in for the same site")
    func windowReuseRule() {
        typealias Content = SiteEnrollmentWindow.Content
        func reuses(
            allowed: Bool = true,
            visible: Bool = true,
            shown: Content? = .form(.adding),
            shownRequest: String? = nil,
            content: Content = .form(.adding),
            request: String? = nil
        ) -> Bool {
            ProVisorSiteWindow.reusesShownForm(
                allowed: allowed,
                isVisible: visible,
                shown: shown,
                shownRequestID: shownRequest,
                content: content,
                requestID: request
            )
        }
        let again = Content.form(.signingInAgain(siteID: "example.com"))

        #expect(reuses())
        #expect(reuses(shownRequest: "p", request: "p"))
        #expect(reuses(shown: again, content: again))
        #expect(!reuses(shownRequest: nil, request: "p"))
        #expect(!reuses(shownRequest: "p", request: nil))
        #expect(!reuses(shownRequest: "p", request: "q"))
        #expect(!reuses(shown: again))
        #expect(!reuses(shown: again, content: .form(.signingInAgain(siteID: "other.example"))))
        #expect(!reuses(shown: nil))
        #expect(!reuses(visible: false))
        #expect(!reuses(allowed: false))

        let signIn = Content.signIn(host: "example.com")
        #expect(reuses(shown: signIn, content: signIn))
        #expect(reuses(shown: signIn, shownRequest: nil, content: signIn, request: "p"))
        #expect(reuses(shown: signIn, shownRequest: "p", content: signIn, request: "q"))
        #expect(!reuses(shown: signIn, content: .signIn(host: "other.example")))
        #expect(!reuses(shown: signIn, content: .form(.adding)))
        #expect(!reuses(shown: .form(.adding), content: signIn))
        #expect(!reuses(shown: signIn, content: again))
        #expect(!reuses(visible: false, shown: signIn, content: signIn))
        #expect(!reuses(allowed: false, shown: signIn, content: signIn))
    }

    @Test("The result names the site")
    func result() {
        #expect(SiteRequests.result(siteName: "Bank") == "Signed in to Bank.")
    }
}

@Suite("ProVisor follow-up demand")
struct FollowUpDemandTests {
    @Test("A pass is owed for a due note, or once after a sign-in until a pass starts that was told of it")
    func demand() {
        var demand = FollowUpDemand()
        #expect(!demand.isOwed(hasDueNote: false))
        #expect(!demand.isOwedAfterGrant)
        #expect(demand.isOwed(hasDueNote: true))
        #expect(demand.justSignedIn.isEmpty)

        demand.requestAfterGrant(site: "example.com")
        #expect(demand.isOwed(hasDueNote: false))
        #expect(demand.isOwedAfterGrant)
        demand.requestAfterGrant(site: "example.com")
        demand.passStarted(told: ["example.com"])
        #expect(!demand.isOwed(hasDueNote: false))
        #expect(!demand.isOwedAfterGrant)
        #expect(demand.isOwed(hasDueNote: true))
    }

    @Test("The sites signed in to are held, sorted, and without repeats, until a pass is told of them")
    func justSignedIn() {
        var demand = FollowUpDemand()
        demand.requestAfterGrant(site: "power.example.org")
        demand.requestAfterGrant(site: "example.com")
        demand.requestAfterGrant(site: "power.example.org")

        #expect(demand.justSignedIn == ["example.com", "power.example.org"])

        demand.passStarted(told: ["example.com", "power.example.org"])
        #expect(demand.justSignedIn.isEmpty)
        #expect(demand == FollowUpDemand())
    }

    @Test("A site signed in to after a pass's list was made stays owed, and a pass told of nothing answers nothing")
    func passAnswersOnlyWhatItWasTold() {
        var demand = FollowUpDemand()
        demand.requestAfterGrant(site: "example.com")
        let told = demand.justSignedIn
        demand.requestAfterGrant(site: "power.example.org")

        demand.passStarted(told: told)

        #expect(demand.justSignedIn == ["power.example.org"])
        #expect(demand.isOwedAfterGrant)

        demand.passStarted(told: [])
        #expect(demand.justSignedIn == ["power.example.org"])
        demand.passStarted(told: ["unrelated.example.net"])
        #expect(demand.justSignedIn == ["power.example.org"])
    }
}
