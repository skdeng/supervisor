import Foundation
import Testing

@testable import SuperVisor

private func signedOut(_ host: String, name: String? = nil, proposalID: String? = nil) -> SignInDemand.Item {
    SignInDemand.Item(
        host: host,
        displayName: name ?? host,
        kind: .signedOut(keepsSession: true),
        proposalID: proposalID
    )
}

private func requested(_ host: String, recognised: Bool) -> SignInDemand.Item {
    SignInDemand.Item(
        host: host,
        displayName: host,
        kind: .requested(recognised: recognised),
        proposalID: "ask-\(host)"
    )
}

private let bank = signedOut("bank.example.com", name: "Bank")
private let power = signedOut("power.example.org", name: "Power")
private let known = requested("known.example.net", recognised: true)
private let stranger = requested("stranger.example", recognised: false)

private func next(
    _ current: ProVisorAnnouncement?,
    _ event: ProVisorAnnouncement.Event
) -> ProVisorAnnouncement? {
    ProVisorAnnouncement.next(current, on: event)
}

@Suite("ProVisor announcement")
struct ProVisorAnnouncementTests {
    // MARK: Ideas

    @Test("Ideas added with nothing up start a count, and more added while it is up add to it")
    func ideasCount() {
        #expect(next(nil, .ideasAdded(2)) == .ideas(2))
        #expect(next(.ideas(2), .ideasAdded(3)) == .ideas(5))
    }

    @Test("Adding no ideas changes nothing, whatever is up")
    func zeroIdeas() {
        #expect(next(nil, .ideasAdded(0)) == nil)
        #expect(next(.ideas(1), .ideasAdded(0)) == .ideas(1))
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .ideasAdded(0)) == .signIn(bank, more: 0, ideasBehind: 0))
    }

    @Test("Ideas arriving under a sign-in leave the sign-in up and are kept behind it")
    func ideasAbsorbedUnderSignIn() {
        #expect(next(.signIn(bank, more: 1, ideasBehind: 0), .ideasAdded(4)) == .signIn(bank, more: 1, ideasBehind: 4))
        #expect(next(.signIn(bank, more: 1, ideasBehind: 4), .ideasAdded(2)) == .signIn(bank, more: 1, ideasBehind: 6))
    }

    @Test("The count's timeout retires a count and nothing else")
    func ideasTimeout() {
        #expect(next(.ideas(3), .ideasTimedOut) == nil)
        #expect(next(nil, .ideasTimedOut) == nil)
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .ideasTimedOut) == .signIn(bank, more: 0, ideasBehind: 0))
    }

    @Test("The glow clearing retires whatever is up")
    func glowClears() {
        #expect(next(nil, .glowCleared) == nil)
        #expect(next(.ideas(2), .glowCleared) == nil)
        #expect(next(.signIn(bank, more: 2, ideasBehind: 0), .glowCleared) == nil)
    }

    // MARK: Sign-in needed

    @Test("A sign-in with nothing up names the first fresh site, counting the others in the demand")
    func signInFromNothing() {
        let demand = [bank, power, known]
        #expect(next(nil, .signInNeeded(fresh: [power, known], demand: demand)) == .signIn(power, more: 2, ideasBehind: 0))
        #expect(next(nil, .signInNeeded(fresh: [bank], demand: [bank])) == .signIn(bank, more: 0, ideasBehind: 0))
    }

    @Test("A sign-in replaces a count and keeps it behind")
    func signInOverIdeas() {
        #expect(next(.ideas(3), .signInNeeded(fresh: [bank], demand: [bank])) == .signIn(bank, more: 0, ideasBehind: 3))
    }

    @Test("A second sign-in under one keeps the named site and grows its count")
    func signInUnderSignIn() {
        let result = next(.signIn(bank, more: 0, ideasBehind: 0), .signInNeeded(fresh: [power], demand: [bank, power]))
        #expect(result == .signIn(bank, more: 1, ideasBehind: 0))
    }

    @Test("A fresh sign-in under a named site that left the demand names the fresh one")
    func signInReplacesResolvedSite() {
        let result = next(.signIn(bank, more: 0, ideasBehind: 0), .signInNeeded(fresh: [power], demand: [power]))
        #expect(result == .signIn(power, more: 0, ideasBehind: 0))
    }

    @Test("A host never visited is never named, nor counted, and leaves what is up alone")
    func unrecognisedRequestIsIgnored() {
        #expect(next(nil, .signInNeeded(fresh: [stranger], demand: [stranger])) == nil)
        #expect(next(.ideas(1), .signInNeeded(fresh: [stranger], demand: [stranger])) == .ideas(1))
        #expect(next(nil, .signInNeeded(fresh: [stranger, bank], demand: [stranger, bank])) == .signIn(bank, more: 0, ideasBehind: 0))
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .demandChanged([bank, stranger])) == .signIn(bank, more: 0, ideasBehind: 0))
    }

    @Test("A requested host the person's browsers know is named like a granted site")
    func recognisedRequestIsNamed() {
        #expect(next(nil, .signInNeeded(fresh: [known], demand: [bank, known])) == .signIn(known, more: 1, ideasBehind: 0))
    }

    @Test("A fresh item missing from the demand is not named")
    func freshItemNotInDemand() {
        #expect(next(nil, .signInNeeded(fresh: [power], demand: [bank])) == nil)
        #expect(next(.ideas(2), .signInNeeded(fresh: [power], demand: [])) == .ideas(2))
    }

    @Test("Nothing fresh to name leaves a count or nothing as it was")
    func nothingFresh() {
        #expect(next(nil, .signInNeeded(fresh: [], demand: [bank])) == nil)
        #expect(next(.ideas(2), .signInNeeded(fresh: [], demand: [bank])) == .ideas(2))
    }

    // MARK: Ideas behind a sign-in

    @Test("A sign-in that leaves the demand unseen gives way to the ideas behind it")
    func ideasSurfaceWhenSignInLeaves() {
        #expect(next(.signIn(bank, more: 0, ideasBehind: 3), .demandChanged([])) == .ideas(3))
        #expect(next(.signIn(bank, more: 1, ideasBehind: 2), .demandChanged([power])) == .ideas(2))
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .demandChanged([])) == nil)
    }

    @Test("A sign-in that leaves while a fresh one arrives keeps the ideas behind the fresh one")
    func ideasMoveBehindTheNextSignIn() {
        let result = next(.signIn(bank, more: 0, ideasBehind: 2), .signInNeeded(fresh: [power], demand: [power]))
        #expect(result == .signIn(power, more: 0, ideasBehind: 2))
    }

    @Test("A sign-in whose site left with nothing fresh gives way to the ideas behind it")
    func ideasSurfaceWhenSignInLeavesWithNothingFresh() {
        #expect(next(.signIn(bank, more: 0, ideasBehind: 2), .signInNeeded(fresh: [], demand: [])) == .ideas(2))
    }

    @Test("Ideas behind a sign-in the person looked at are not announced")
    func ideasGoWhenTheClaimEnds() {
        #expect(next(.signIn(bank, more: 0, ideasBehind: 3), .glowCleared) == nil)
    }

    @Test("The ideas timeout leaves ideas behind a sign-in where they are")
    func ideasTimeoutLeavesHiddenIdeas() {
        #expect(next(.signIn(bank, more: 0, ideasBehind: 3), .ideasTimedOut) == .signIn(bank, more: 0, ideasBehind: 3))
    }

    @Test("The ideas behind a sign-in survive a refresh of it in place")
    func ideasSurviveRefresh() {
        #expect(next(.signIn(bank, more: 0, ideasBehind: 3), .demandChanged([bank, power])) == .signIn(bank, more: 1, ideasBehind: 3))
    }

    // MARK: Demand changed

    @Test("The named site leaving the demand retires the banner, and no other site takes its place")
    func retiresWhenNamedSiteLeaves() {
        #expect(next(.signIn(bank, more: 1, ideasBehind: 0), .demandChanged([power])) == nil)
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .demandChanged([])) == nil)
    }

    @Test("The named site stays, with its count refreshed, as others come and go")
    func refreshesMore() {
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .demandChanged([bank, power, known])) == .signIn(bank, more: 2, ideasBehind: 0))
        #expect(next(.signIn(bank, more: 2, ideasBehind: 0), .demandChanged([bank])) == .signIn(bank, more: 0, ideasBehind: 0))
    }

    @Test("The named site is refreshed in place when its item changes")
    func refreshesItem() {
        let renamed = signedOut("bank.example.com", name: "My Bank", proposalID: "check-bank")
        #expect(next(.signIn(bank, more: 0, ideasBehind: 0), .demandChanged([renamed])) == .signIn(renamed, more: 0, ideasBehind: 0))
    }

    @Test("A change of demand leaves a count or nothing alone")
    func demandChangeLeavesIdeas() {
        #expect(next(nil, .demandChanged([bank])) == nil)
        #expect(next(.ideas(2), .demandChanged([bank, power])) == .ideas(2))
    }
}

@Suite("ProVisor announcement effects")
struct ProVisorAnnouncementEffectsTests {
    private typealias Effects = ProVisorAnnouncement.Effects

    private func effects(_ old: ProVisorAnnouncement?, _ new: ProVisorAnnouncement?) -> Effects {
        Effects.between(old, new)
    }

    @Test("Nothing changing asks for nothing")
    func unchanged() {
        #expect(effects(nil, nil) == Effects())
        #expect(effects(.ideas(2), .ideas(2)) == Effects())
        #expect(effects(.signIn(bank, more: 1, ideasBehind: 0), .signIn(bank, more: 1, ideasBehind: 0)) == Effects())
    }

    @Test("A sign-in from nothing raises the glow and takes the hold")
    func signInFromNothing() {
        #expect(effects(nil, .signIn(bank, more: 0, ideasBehind: 0))
            == Effects(raisesGlow: true, holds: true, refreshes: true))
    }

    @Test("A count from nothing raises the glow, takes the hold, and starts its timeout")
    func ideasFromNothing() {
        #expect(effects(nil, .ideas(2))
            == Effects(raisesGlow: true, holds: true, ideasTimer: .start, refreshes: true))
    }

    @Test("A count that grows restarts its timeout within the hold")
    func ideasGrow() {
        #expect(effects(.ideas(2), .ideas(5)) == Effects(raisesGlow: true, ideasTimer: .start, refreshes: true))
    }

    @Test("The same site with another count neither re-raises nor re-holds")
    func signInRefreshed() {
        #expect(effects(.signIn(bank, more: 0, ideasBehind: 0), .signIn(bank, more: 2, ideasBehind: 0))
            == Effects(refreshes: true))
        #expect(effects(.signIn(bank, more: 0, ideasBehind: 0), .signIn(bank, more: 0, ideasBehind: 4))
            == Effects(refreshes: true))
    }

    @Test("Another site named within the hold raises the glow and takes no second hold")
    func signInRenamed() {
        #expect(effects(.signIn(bank, more: 0, ideasBehind: 0), .signIn(power, more: 0, ideasBehind: 0))
            == Effects(raisesGlow: true, refreshes: true))
    }

    @Test("A sign-in withdrawn releases the hold")
    func signInWithdrawn() {
        #expect(effects(.signIn(bank, more: 0, ideasBehind: 0), nil) == Effects(releases: true, refreshes: true))
    }

    @Test("A count withdrawn releases the hold and cancels its timeout")
    func ideasWithdrawn() {
        #expect(effects(.ideas(3), nil) == Effects(releases: true, ideasTimer: .cancel, refreshes: true))
    }

    @Test("A sign-in replacing a count raises the glow and cancels the count's timeout")
    func ideasToSignIn() {
        #expect(effects(.ideas(3), .signIn(bank, more: 0, ideasBehind: 3))
            == Effects(raisesGlow: true, ideasTimer: .cancel, refreshes: true))
    }

    @Test("A count surfacing from behind a sign-in starts its timeout within the hold")
    func signInToIdeas() {
        #expect(effects(.signIn(bank, more: 0, ideasBehind: 3), .ideas(3))
            == Effects(ideasTimer: .start, refreshes: true))
    }
}
