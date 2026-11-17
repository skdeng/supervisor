import Foundation
import Testing

@testable import SuperVisor

private let now = Date(timeIntervalSince1970: 1_794_762_720)

private func proposal(
    _ id: String,
    site: String?,
    createdAgo: TimeInterval = 60,
    status: Proposal.Status = .proposed,
    expiresIn: TimeInterval? = nil
) -> Proposal {
    Proposal(
        id: id,
        title: id,
        why: nil,
        options: [ProposalOption(label: "Suggested", action: "a")],
        kind: "confirm",
        created: now.addingTimeInterval(-createdAgo),
        expires: expiresIn.map { now.addingTimeInterval($0) },
        status: status,
        result: nil,
        isCleared: false,
        site: site
    )
}

private func site(
    _ host: String,
    name: String? = nil,
    needsPerson: Bool = false,
    keepsSessionOnly: Bool = false
) -> SiteRecord {
    var record = SiteRecord(id: host, name: name ?? host, added: now.addingTimeInterval(-86_400))
    record.needsPerson = needsPerson
    record.keepsSessionOnly = keepsSessionOnly
    return record
}

private func items(
    proposals: [Proposal] = [],
    sites: [SiteRecord] = [],
    awaiting: Set<String> = [],
    recognised: @escaping (String) -> Bool? = { _ in false }
) -> [SignInDemand.Item] {
    SignInDemand.items(
        proposals: proposals,
        sites: sites,
        awaiting: awaiting,
        now: now,
        recognised: recognised
    )
}

@Suite("Sign-in demand")
struct SignInDemandTests {
    @Test("With nothing flagged, awaited, or asked for there is no demand")
    func nothing() {
        #expect(items().isEmpty)
        #expect(items(
            proposals: [proposal("a", site: nil)],
            sites: [site("example.com"), site("power.example.org")]
        ).isEmpty)
    }

    @Test("A granted site flagged as needing the person is in demand, by its name and how it is kept")
    func flaggedSite() {
        let result = items(sites: [
            site("example.com", name: "Bank", needsPerson: true, keepsSessionOnly: true),
            site("power.example.org", name: "City Power"),
        ])

        #expect(result == [
            SignInDemand.Item(
                host: "example.com",
                displayName: "Bank",
                kind: .signedOut(keepsSession: true),
                proposalID: nil
            ),
        ])
        #expect(result.first?.id == "example.com")
    }

    @Test("A granted site a run was turned away from is in demand though its record is clean")
    func awaitedSite() {
        let result = items(
            sites: [site("example.com", name: "Bank"), site("power.example.org", name: "City Power")],
            awaiting: ["power.example.org"]
        )

        #expect(result == [
            SignInDemand.Item(
                host: "power.example.org",
                displayName: "City Power",
                kind: .signedOut(keepsSession: false),
                proposalID: nil
            ),
        ])
    }

    @Test("An awaited id that is not a granted site is not in demand")
    func awaitedButNotGranted() {
        #expect(items(sites: [site("example.com")], awaiting: ["gone.example.org"]).isEmpty)
    }

    @Test("A request for a host that is not granted is an item named by the host, with whether it is recognised")
    func requestedHost() {
        for known in [true, false] {
            let result = items(
                proposals: [proposal("a-clear", site: "clear.example.com")],
                recognised: { $0 == "clear.example.com" ? known : !known }
            )

            #expect(result == [
                SignInDemand.Item(
                    host: "clear.example.com",
                    displayName: "clear.example.com",
                    kind: .requested(recognised: known),
                    proposalID: "a-clear"
                ),
            ], "recognised \(known)")
        }
    }

    @Test("Whether a host is recognised is asked only of hosts that are requested and not granted")
    func recognitionIsAskedOnlyWhenNeeded() {
        var asked: [String] = []
        _ = items(
            proposals: [
                proposal("a-granted", site: "example.com"),
                proposal("b-new", site: "new.example.org"),
            ],
            sites: [site("example.com", needsPerson: true)],
            recognised: { asked.append($0); return true }
        )

        #expect(asked == ["new.example.org"])
    }

    @Test("A request for a granted host joins that site's item and gives it the proposal's id")
    func requestMergesIntoGrantedSite() {
        let result = items(
            proposals: [proposal("a-bank", site: "example.com")],
            sites: [site("example.com", name: "Bank", needsPerson: true)]
        )

        #expect(result == [
            SignInDemand.Item(
                host: "example.com",
                displayName: "Bank",
                kind: .signedOut(keepsSession: false),
                proposalID: "a-bank"
            ),
        ])
    }

    @Test("A request for a granted site that is neither flagged nor awaited puts nothing in demand")
    func requestAloneDoesNotPutAHealthySiteInDemand() {
        let result = items(
            proposals: [proposal("a-bank", site: "example.com")],
            sites: [site("example.com", name: "Bank")]
        )

        #expect(result.isEmpty)
    }

    @Test("A request for a granted site that is awaited joins its item")
    func requestMergesIntoAwaitedSite() {
        let result = items(
            proposals: [proposal("a-bank", site: "example.com")],
            sites: [site("example.com", name: "Bank")],
            awaiting: ["example.com"]
        )

        #expect(result.map(\.host) == ["example.com"])
        #expect(result.first?.kind == .signedOut(keepsSession: false))
        #expect(result.first?.proposalID == "a-bank")
    }

    @Test("A requested host is left out until its recognition is known, and appears with the answer")
    func requestWaitsForRecognition() {
        let proposals = [
            proposal("a-new", site: "new.example.org", createdAgo: 60),
            proposal("b-known", site: "known.example.org", createdAgo: 30),
        ]
        func answer(_ host: String) -> Bool? { host == "known.example.org" ? true : nil }

        let pending = items(
            proposals: proposals,
            sites: [site("example.com", name: "Bank", needsPerson: true)],
            recognised: answer
        )

        // A granted site that needs the person never waits on a lookup.
        #expect(pending.map(\.host) == ["example.com", "known.example.org"])

        let answered = items(proposals: proposals, recognised: { $0 == "known.example.org" ? true : false })
        #expect(answered.map(\.host) == ["new.example.org", "known.example.org"])
        #expect(answered.map(\.kind) == [.requested(recognised: false), .requested(recognised: true)])
        #expect(items(proposals: proposals, recognised: { _ in nil }).isEmpty)
    }

    @Test("Repeated requests for a host collapse to the earliest, for a granted site and for any other")
    func repeatedRequestsCollapse() {
        let proposals = [
            proposal("b-later", site: "example.com", createdAgo: 60),
            proposal("a-first", site: "example.com", createdAgo: 600),
            proposal("d-later", site: "new.example.org", createdAgo: 30),
            proposal("c-first", site: "new.example.org", createdAgo: 90),
        ]

        let result = items(
            proposals: proposals,
            sites: [site("example.com", name: "Bank", needsPerson: true)]
        )

        #expect(result.map(\.host) == ["example.com", "new.example.org"])
        #expect(result.map(\.proposalID) == ["a-first", "c-first"])
    }

    @Test("A request that expired or was decided is not in demand, and does not hide a later open one")
    func closedRequestsAreExcluded() {
        let closed = [
            proposal("a-expired", site: "example.com", createdAgo: 900, expiresIn: -1),
            proposal("b-done", site: "example.com", createdAgo: 800, status: .done),
            proposal("c-dismissed", site: "example.com", createdAgo: 700, status: .dismissed),
            proposal("d-withdrawn", site: "example.com", createdAgo: 600, status: .withdrawn),
        ]

        #expect(items(proposals: closed).isEmpty)

        let open = items(proposals: closed + [proposal("e-open", site: "example.com", createdAgo: 30)])
        #expect(open.map(\.proposalID) == ["e-open"])
    }

    @Test("A request that failed can still be decided, so it is still in demand")
    func failedRequestIsOpen() {
        let result = items(proposals: [proposal("a-failed", site: "example.com", status: .failed)])

        #expect(result.map(\.proposalID) == ["a-failed"])
    }

    @Test("A request is judged at the time given: it expires then, not before")
    func expiryFollowsTheClock() {
        let asking = [proposal("a-soon", site: "example.com", expiresIn: 3_600)]

        #expect(SignInDemand.items(
            proposals: asking, sites: [], awaiting: [], now: now, recognised: { _ in false }
        ).count == 1)
        #expect(SignInDemand.items(
            proposals: asking, sites: [], awaiting: [], now: now.addingTimeInterval(3_600), recognised: { _ in false }
        ).isEmpty)
    }

    @Test("Granted sites come first by name and then host, then requests by when they were asked for and then host")
    func ordering() {
        let proposals = [
            proposal("p-new", site: "new.example.org", createdAgo: 60),
            proposal("p-old", site: "old.example.org", createdAgo: 600),
            proposal("p-tie-b", site: "tie-b.example.org", createdAgo: 120),
            proposal("p-tie-a", site: "tie-a.example.org", createdAgo: 120),
        ]
        let sites = [
            site("zeta.example.com", name: "Zeta", needsPerson: true),
            site("b.example.com", name: "alpha", needsPerson: true),
            site("a.example.com", name: "Alpha", needsPerson: true),
            site("mid.example.com", name: "Mid", needsPerson: true),
        ]

        let result = items(proposals: proposals, sites: sites)

        #expect(result.map(\.host) == [
            "a.example.com", "b.example.com", "mid.example.com", "zeta.example.com",
            "old.example.org", "tie-a.example.org", "tie-b.example.org", "new.example.org",
        ])
        #expect(items(proposals: proposals.reversed(), sites: sites.reversed()) == result)
    }

    @Test("The hosts awaiting recognition are the requested hosts that are not granted and have no answer yet")
    func hostsAwaitingRecognition() {
        let proposals = [
            proposal("a-new", site: "new.example.org"),
            proposal("b-known", site: "known.example.org"),
            proposal("c-granted", site: "example.com"),
            proposal("d-expired", site: "expired.example.net", expiresIn: -1),
        ]
        let pending = SignInDemand.hostsAwaitingRecognition(
            proposals: proposals,
            sites: [site("example.com")],
            now: now,
            recognised: { $0 == "known.example.org" ? false : nil }
        )

        #expect(pending == ["new.example.org"])
    }

    @Test("The open requests are the earliest per host among those that can still be decided")
    func openRequests() {
        let proposals = [
            proposal("a-first", site: "example.com", createdAgo: 600),
            proposal("b-later", site: "example.com", createdAgo: 60),
            proposal("c-expired", site: "expired.example.org", expiresIn: -5),
            proposal("d-none", site: nil),
        ]

        let requests = SignInDemand.openRequests(in: proposals, now: now)

        #expect(requests.mapValues(\.id) == ["example.com": "a-first"])
    }
}

@Suite("What saving a sign-in does")
struct SignInSaveEffectTests {
    private func effect(
        _ siteID: String = "example.com",
        proposals: [Proposal] = [],
        wasAwaited: Bool = false
    ) -> SignInDemand.SaveEffect {
        SignInDemand.effectOfSaving(siteID, proposals: proposals, now: now, wasAwaited: wasAwaited)
    }

    @Test("A save for a site that was waiting on the person owes a pass with no request to settle")
    func awaitedSiteWithNoRequest() {
        #expect(effect(wasAwaited: true) == SignInDemand.SaveEffect(settles: nil, owesPass: true))
    }

    @Test("A save for a site that was not waiting and that nothing asks for owes nothing")
    func siteNotInDemand() {
        #expect(effect() == SignInDemand.SaveEffect(settles: nil, owesPass: false))
        #expect(effect(proposals: [proposal("a-none", site: nil)]) == SignInDemand.SaveEffect(settles: nil, owesPass: false))
    }

    @Test("A save for a site an open proposal asks for settles that proposal and owes a pass, awaited or not")
    func requestedSite() {
        let asking = [proposal("a-bank", site: "example.com")]

        #expect(effect(proposals: asking) == SignInDemand.SaveEffect(settles: "a-bank", owesPass: true))
        #expect(effect(proposals: asking, wasAwaited: true) == SignInDemand.SaveEffect(settles: "a-bank", owesPass: true))
    }

    @Test("Of several open requests for the site the earliest is the one settled")
    func earliestRequestSettles() {
        let asking = [
            proposal("b-later", site: "example.com", createdAgo: 60),
            proposal("a-first", site: "example.com", createdAgo: 600),
        ]

        #expect(effect(proposals: asking).settles == "a-first")
    }

    @Test("A request for another site settles nothing and owes nothing, whatever window the save came from")
    func otherSiteRequest() {
        let asking = [proposal("a-other", site: "other.example.org")]

        #expect(effect(proposals: asking) == SignInDemand.SaveEffect(settles: nil, owesPass: false))
        #expect(effect(proposals: asking, wasAwaited: true) == SignInDemand.SaveEffect(settles: nil, owesPass: true))
    }

    @Test("A request that expired or was decided is not answered by a save")
    func closedRequests() {
        let closed = [
            proposal("a-expired", site: "example.com", createdAgo: 900, expiresIn: -1),
            proposal("b-done", site: "example.com", createdAgo: 800, status: .done),
            proposal("c-dismissed", site: "example.com", createdAgo: 700, status: .dismissed),
            proposal("d-withdrawn", site: "example.com", createdAgo: 600, status: .withdrawn),
        ]

        #expect(effect(proposals: closed) == SignInDemand.SaveEffect(settles: nil, owesPass: false))
    }
}

@Suite("Sign-in announcer")
struct SignInAnnouncerTests {
    private func item(_ host: String) -> SignInDemand.Item {
        SignInDemand.Item(
            host: host,
            displayName: host,
            kind: .signedOut(keepsSession: false),
            proposalID: nil
        )
    }

    @Test("Nothing is news before the first load has seeded it")
    func unseeded() {
        var announcer = SignInAnnouncer()

        #expect(announcer.newItems(in: [item("example.com")]).isEmpty)
        // Looking before the seed leaves the seed to the first load.
        announcer.seedIfNeeded(with: [item("example.com")])
        #expect(announcer.newItems(in: [item("example.com")]).isEmpty)
    }

    @Test("Items present at the first load are known, and a later one is announced once")
    func seededAtFirstLoad() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [item("example.com")])

        #expect(announcer.newItems(in: [item("example.com")]).isEmpty)
        #expect(announcer.newItems(in: [item("example.com"), item("power.example.org")]).map(\.host)
            == ["power.example.org"])
        #expect(announcer.newItems(in: [item("example.com"), item("power.example.org")]).isEmpty)
    }

    @Test("A later seed changes nothing")
    func seedsOnce() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [])
        announcer.seedIfNeeded(with: [item("example.com")])

        #expect(announcer.newItems(in: [item("example.com")]).map(\.host) == ["example.com"])
    }

    @Test("A host that left the demand and came back is announced again")
    func announcesAgainAfterLeaving() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [])

        #expect(announcer.newItems(in: [item("example.com")]).map(\.host) == ["example.com"])
        #expect(announcer.newItems(in: [item("example.com")]).isEmpty)
        #expect(announcer.newItems(in: []).isEmpty)
        #expect(announcer.newItems(in: [item("example.com")]).map(\.host) == ["example.com"])
    }

    @Test("A host in demand at the first load whose item is still being prepared is known, and is not announced when it appears")
    func pendingAtFirstLoadIsKnown() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [item("known.example.com")], pending: ["waiting.example.org"])

        #expect(announcer.newItems(in: [item("known.example.com")], pending: ["waiting.example.org"]).isEmpty)
        #expect(announcer.newItems(in: [item("known.example.com")], pending: ["waiting.example.org"]).isEmpty)
        #expect(announcer.newItems(in: [item("known.example.com"), item("waiting.example.org")]).isEmpty)
    }

    @Test("A host that arrives after the first load and is still being prepared is announced with its item")
    func pendingAfterFirstLoadIsAnnouncedLater() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [item("known.example.com")])

        #expect(announcer.newItems(in: [item("known.example.com")], pending: ["new.example.org"]).isEmpty)
        #expect(announcer.newItems(in: [item("known.example.com")], pending: ["new.example.org"]).isEmpty)
        #expect(announcer.newItems(in: [item("known.example.com"), item("new.example.org")]).map(\.host)
            == ["new.example.org"])
    }

    @Test("A pending host that leaves the demand without ever having an item is forgotten")
    func pendingThatLeavesIsForgotten() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [], pending: ["waiting.example.org"])

        #expect(announcer.newItems(in: [], pending: []).isEmpty)
        #expect(announcer.newItems(in: [item("waiting.example.org")]).map(\.host) == ["waiting.example.org"])
    }

    @Test("Several new hosts are announced together, in the order given")
    func severalAtOnce() {
        var announcer = SignInAnnouncer()
        announcer.seedIfNeeded(with: [item("known.example.com")])

        let fresh = announcer.newItems(in: [item("known.example.com"), item("b.example.com"), item("a.example.com")])

        #expect(fresh.map(\.host) == ["b.example.com", "a.example.com"])
    }
}

@Suite("Sign-in prompts")
struct SignInPromptTests {
    private func item(
        _ host: String,
        _ kind: SignInDemand.Item.Kind,
        proposalID: String? = nil
    ) -> SignInDemand.Item {
        SignInDemand.Item(host: host, displayName: host, kind: kind, proposalID: proposalID)
    }

    @Test(
        "Only a granted site or a host the person's browsers know may be announced",
        arguments: [
            (SignInDemand.Item.Kind.signedOut(keepsSession: true), true),
            (.signedOut(keepsSession: false), true),
            (.requested(recognised: true), true),
            (.requested(recognised: false), false),
        ]
    )
    func announceable(kind: SignInDemand.Item.Kind, expected: Bool) {
        #expect(item("example.com", kind).isAnnounceable == expected)
    }

    @Test("Prompts drop hosts never visited and granted sites put off, and keep the order")
    func prompts() {
        let items = [
            item("bank.example.com", .signedOut(keepsSession: true)),
            item("power.example.org", .signedOut(keepsSession: false)),
            item("known.example.net", .requested(recognised: true), proposalID: "a"),
            item("stranger.example", .requested(recognised: false), proposalID: "b"),
        ]

        #expect(SignInDemand.prompts(in: items, postponed: []).map(\.host)
            == ["bank.example.com", "power.example.org", "known.example.net"])
        #expect(SignInDemand.prompts(in: items, postponed: ["bank.example.com"]).map(\.host)
            == ["power.example.org", "known.example.net"])
    }

    @Test("A requested host is offered even when its host is in the put-off set")
    func requestedHostIsNeverPutOff() {
        let items = [item("known.example.net", .requested(recognised: true), proposalID: "a")]
        #expect(SignInDemand.prompts(in: items, postponed: ["known.example.net"]) == items)
    }

    @Test("The proposals covered are those the prompts carry")
    func coveredProposals() {
        let prompts = [
            item("bank.example.com", .signedOut(keepsSession: true)),
            item("power.example.org", .signedOut(keepsSession: false), proposalID: "check-power"),
            item("known.example.net", .requested(recognised: true), proposalID: "ask-known"),
        ]
        #expect(SignInDemand.coveredProposalIDs(prompts) == ["check-power", "ask-known"])
        #expect(SignInDemand.coveredProposalIDs([]).isEmpty)
    }

    // MARK: Postponements

    @Test("Putting off a granted site hides it until a run is turned away from it again")
    func postponeUntilTurnedAway() {
        let bank = item("bank.example.com", .signedOut(keepsSession: true))
        var postponements = SignInPostponements()
        postponements.postpone(bank)
        #expect(postponements.hosts == ["bank.example.com"])

        postponements.turnedAway("other.example")
        #expect(postponements.hosts == ["bank.example.com"])
        postponements.turnedAway("bank.example.com")
        #expect(postponements.hosts.isEmpty)
    }

    @Test("A requested host cannot be put off")
    func requestedCannotBePostponed() {
        var postponements = SignInPostponements()
        postponements.postpone(item("known.example.net", .requested(recognised: true), proposalID: "a"))
        #expect(postponements.hosts.isEmpty)
    }

    @Test("A site put off is forgotten once it is no longer a granted site in demand: saved, removed, or read")
    func pruneForgetsSitesThatLeft() {
        let bank = item("bank.example.com", .signedOut(keepsSession: true))
        let power = item("power.example.org", .signedOut(keepsSession: false))
        var postponements = SignInPostponements()
        postponements.postpone(bank)
        postponements.postpone(power)

        postponements.prune(keeping: [bank, power])
        #expect(postponements.hosts == ["bank.example.com", "power.example.org"])

        // A removed site that a proposal still asks for comes back as a request.
        postponements.prune(keeping: [bank, item("power.example.org", .requested(recognised: true), proposalID: "a")])
        #expect(postponements.hosts == ["bank.example.com"])

        postponements.prune(keeping: [])
        #expect(postponements.hosts.isEmpty)
    }

    // MARK: Expiry

    @Test("The next expiry is the soonest among the open requests, and none when none expires")
    func nextExpiry() {
        let proposals = [
            proposal("a-later", site: "a.example.com", expiresIn: 7200),
            proposal("b-sooner", site: "b.example.com", expiresIn: 600),
            proposal("c-never", site: "c.example.com"),
            proposal("d-plain", site: nil, expiresIn: 60),
            proposal("e-decided", site: "e.example.com", status: .done, expiresIn: 30),
            proposal("f-expired", site: "f.example.com", expiresIn: -5),
        ]

        #expect(SignInDemand.nextExpiry(of: proposals, now: now) == now.addingTimeInterval(600))
        #expect(SignInDemand.nextExpiry(of: [proposal("c-never", site: "c.example.com")], now: now) == nil)
        #expect(SignInDemand.nextExpiry(of: [], now: now) == nil)
    }

    @Test("A repeated request's expiry is not the open request's")
    func repeatedRequestExpiryIsIgnored() {
        let proposals = [
            proposal("a-first", site: "example.com", createdAgo: 600),
            proposal("b-again", site: "example.com", createdAgo: 60, expiresIn: 30),
        ]
        #expect(SignInDemand.nextExpiry(of: proposals, now: now) == nil)
    }
}

@Suite("Requests awaiting recognition")
struct RequestsAwaitingRecognitionTests {
    @Test("The ids are the open requests for the hosts named, the earliest per host")
    func requestIDs() {
        let proposals = [
            proposal("a-first", site: "known.example", createdAgo: 600),
            proposal("b-again", site: "known.example", createdAgo: 60),
            proposal("c-other", site: "other.example", createdAgo: 60),
            proposal("d-closed", site: "closed.example", status: .dismissed),
        ]

        #expect(SignInDemand.requestIDs(forHosts: ["known.example", "closed.example"], in: proposals, now: now)
            == ["a-first"])
        #expect(SignInDemand.requestIDs(forHosts: [], in: proposals, now: now).isEmpty)
    }
}
