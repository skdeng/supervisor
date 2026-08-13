import Foundation
import Testing

@testable import SuperVisor

@MainActor
@Suite("Sheet section ordering")
struct SheetSectionOrderingTests {
    private struct Section: SheetSection, Equatable {
        let moduleID: String
        let order: Int
        var isPinned = false
        var isUrgent = false
    }

    @Test("Quiet sections keep module order")
    func quietSectionsFollowModuleOrder() {
        let sorted = SheetSectionOrdering.sorted([
            Section(moduleID: "usage", order: 90),
            Section(moduleID: "media", order: 10),
            Section(moduleID: "calendar", order: 20),
        ])

        #expect(sorted.map(\.moduleID) == ["media", "calendar", "usage"])
    }

    @Test("An urgent section leads whatever its module order")
    func urgentSectionLeads() {
        let sorted = SheetSectionOrdering.sorted([
            Section(moduleID: "media", order: 10),
            Section(moduleID: "usage", order: 90, isUrgent: true),
            Section(moduleID: "calendar", order: 20),
        ])

        #expect(sorted.map(\.moduleID) == ["usage", "media", "calendar"])
    }

    @Test("Urgent sections keep module order among themselves")
    func urgentSectionsFollowModuleOrder() {
        let sorted = SheetSectionOrdering.sorted([
            Section(moduleID: "media", order: 10),
            Section(moduleID: "calendar", order: 20, isUrgent: true),
            Section(moduleID: "swarm", order: 15, isUrgent: true),
        ])

        #expect(sorted.map(\.moduleID) == ["swarm", "calendar", "media"])
    }

    @Test("The pinned section leads even while another section is urgent")
    func pinnedSectionOutranksUrgency() {
        let sorted = SheetSectionOrdering.sorted([
            Section(moduleID: "calendar", order: 20, isUrgent: true),
            Section(moduleID: "media", order: 10, isPinned: true),
            Section(moduleID: "swarm", order: 15, isUrgent: true),
        ])

        #expect(sorted.map(\.moduleID) == ["media", "swarm", "calendar"])
    }

    @Test("A pinned section leads from any module order")
    func pinnedSectionIgnoresModuleOrder() {
        let sorted = SheetSectionOrdering.sorted([
            Section(moduleID: "swarm", order: 15),
            Section(moduleID: "usage", order: 90, isPinned: true),
        ])

        #expect(sorted.map(\.moduleID) == ["usage", "swarm"])
    }

    @Test("Sections sharing an order sort deterministically")
    func equalOrdersResolveByModuleID() {
        let input = [
            Section(moduleID: "zeta", order: 50),
            Section(moduleID: "alpha", order: 50),
            Section(moduleID: "mu", order: 50),
        ]

        #expect(SheetSectionOrdering.sorted(input).map(\.moduleID) == ["alpha", "mu", "zeta"])
        #expect(SheetSectionOrdering.sorted(input.reversed()).map(\.moduleID) == ["alpha", "mu", "zeta"])
    }
}

@MainActor
@Suite("Sheet overflow fade")
struct SheetOverflowFadeTests {
    @Test("Content that fits is not faded")
    func fittingContentHasNoBand() {
        #expect(SheetOverflowFade.band(contentHeight: 420, visibleHeight: 600) == nil)
        #expect(SheetOverflowFade.band(contentHeight: 600, visibleHeight: 600) == nil)
    }

    @Test("The fade ends exactly at the cut and spans the band height")
    func bandEndsAtTheVisibleCut() throws {
        let band = try #require(SheetOverflowFade.band(contentHeight: 1200, visibleHeight: 600))

        // The mask spans the full 1200pt of content, of which the top 600pt is on screen.
        #expect(abs(band.end - 0.5) < 0.0001)
        #expect(abs(band.start - (600 - SheetOverflowFade.bandHeight) / 1200) < 0.0001)
        #expect(band.start < band.end)
    }

    @Test("A visible height shorter than the band still yields ordered stops")
    func shallowVisibleHeightClampsToZero() throws {
        let band = try #require(SheetOverflowFade.band(contentHeight: 100, visibleHeight: 20))

        #expect(band.start == 0)
        #expect(band.start < band.end)
    }

    @Test("A sheet with no measured content is not faded")
    func zeroHeightsAreInert() {
        #expect(SheetOverflowFade.band(contentHeight: 0, visibleHeight: 600) == nil)
        #expect(SheetOverflowFade.band(contentHeight: 800, visibleHeight: 0) == nil)
    }
}

@MainActor
@Suite("Attention queue curation")
struct SwarmQueuePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        pid: Int32,
        reason: AttentionReason,
        secondsAgo: TimeInterval
    ) -> AttentionEntry {
        AttentionEntry(
            sessionPID: pid,
            name: "session-\(pid)",
            cwd: "/tmp/session-\(pid)",
            tty: nil,
            reason: reason,
            since: now.addingTimeInterval(-secondsAgo)
        )
    }

    @Test("A session that stopped long ago folds away")
    func longIdleSessionsFold() {
        let split = SwarmQueuePresentation.split(
            [
                entry(pid: 1, reason: .finished(turnDuration: 90, summary: nil), secondsAgo: 86_400),
                entry(pid: 2, reason: .finished(turnDuration: 90, summary: nil), secondsAgo: 120),
            ],
            now: now
        )

        #expect(split.current.map(\.sessionPID) == [2])
        #expect(split.idle.map(\.sessionPID) == [1])
    }

    @Test("A blocked session keeps its row however long it has waited")
    func blockedSessionsNeverFold() {
        let split = SwarmQueuePresentation.split(
            [
                entry(pid: 1, reason: .failed(error: "rate_limit", details: nil), secondsAgo: 604_800),
                entry(pid: 2, reason: .waiting(detail: "approve Bash"), secondsAgo: 604_800),
            ],
            now: now
        )

        #expect(split.idle.isEmpty)
        #expect(Set(split.current.map(\.sessionPID)) == [1, 2])
    }

    @Test("A question or an idle prompt folds once it is old enough")
    func nonBlockingReasonsFoldOnAge() {
        let split = SwarmQueuePresentation.split(
            [
                entry(pid: 1, reason: .asked(question: "Ship it?"), secondsAgo: 7_200),
                entry(pid: 2, reason: .needsInput, secondsAgo: 7_200),
                entry(pid: 3, reason: .asked(question: "Ship it?"), secondsAgo: 60),
            ],
            now: now
        )

        #expect(split.current.map(\.sessionPID) == [3])
        #expect(Set(split.idle.map(\.sessionPID)) == [1, 2])
    }

    @Test("A session exactly at the fold age folds")
    func theFoldAgeIsInclusive() {
        let split = SwarmQueuePresentation.split(
            [
                entry(
                    pid: 1,
                    reason: .finished(turnDuration: nil, summary: nil),
                    secondsAgo: SwarmQueuePresentation.idleFoldAge
                ),
                entry(
                    pid: 2,
                    reason: .finished(turnDuration: nil, summary: nil),
                    secondsAgo: SwarmQueuePresentation.idleFoldAge - 1
                ),
            ],
            now: now
        )

        #expect(split.current.map(\.sessionPID) == [2])
        #expect(split.idle.map(\.sessionPID) == [1])
    }

    @Test("Blocked sessions lead, then the most recent")
    func blockedLeadsThenRecency() {
        let split = SwarmQueuePresentation.split(
            [
                entry(pid: 1, reason: .finished(turnDuration: 90, summary: nil), secondsAgo: 30),
                entry(pid: 2, reason: .waiting(detail: "dialog open"), secondsAgo: 300),
                entry(pid: 3, reason: .needsInput, secondsAgo: 120),
            ],
            now: now
        )

        #expect(split.current.map(\.sessionPID) == [2, 1, 3])
    }

    @Test("Sessions stopped at the same instant sort deterministically")
    func identicalTimestampsResolveByPID() {
        let entries = [
            entry(pid: 9, reason: .needsInput, secondsAgo: 60),
            entry(pid: 3, reason: .needsInput, secondsAgo: 60),
            entry(pid: 7, reason: .needsInput, secondsAgo: 60),
        ]

        #expect(SwarmQueuePresentation.split(entries, now: now).current.map(\.sessionPID) == [3, 7, 9])
        #expect(
            SwarmQueuePresentation.split(entries.reversed(), now: now).current.map(\.sessionPID) == [3, 7, 9]
        )
    }

    @Test("An empty queue splits into nothing")
    func emptyQueue() {
        let split = SwarmQueuePresentation.split([], now: now)

        #expect(split.current.isEmpty)
        #expect(split.idle.isEmpty)
    }
}
