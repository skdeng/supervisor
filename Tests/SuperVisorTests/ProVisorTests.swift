import Foundation
import Testing

@testable import SuperVisor

/// A proposal file is written by a model that has been reading mail from anyone, so what is
/// under test is mostly what must be refused or cleaned before text reaches a view or a prompt.
@Suite("ProVisor proposal files")
struct ProposalParsingTests {
    private let modified = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(
        _ fields: [String: Any],
        id: String = "2026-11-15-example"
    ) -> Proposal? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return Proposal.parse(data, id: id, modified: modified)
    }

    @Test("A minimal file is a waiting proposal dated by the file")
    func minimalFile() {
        let proposal = parse(["title": "Cancel Foo Pro", "action": "Draft the email."])

        #expect(proposal?.status == .proposed)
        #expect(proposal?.created == modified)
        #expect(proposal?.why == nil)
        #expect(proposal?.isCleared == false)
    }

    @Test("Stated dates and status are read")
    func statedFields() {
        let proposal = parse([
            "title": "Cancel Foo Pro",
            "action": "Draft the email.",
            "created": "2026-11-15T17:12:00Z",
            "status": "done",
            "kind": "subscription-cancel",
            "cleared": true,
        ])

        #expect(proposal?.created == Date(timeIntervalSince1970: 1_794_762_720))
        #expect(proposal?.status == .done)
        #expect(proposal?.kind == "subscription-cancel")
        #expect(proposal?.isCleared == true)
    }

    @Test("An action too long to show whole is refused, never shortened")
    func overlongActionIsRefused() {
        let atLimit = String(repeating: "a", count: Proposal.actionLimit)

        #expect(parse(["title": "t", "action": atLimit])?.action == atLimit)
        #expect(parse(["title": "t", "action": atLimit + "a"]) == nil)
    }

    @Test("A long title is cut to the limit")
    func overlongTitleIsCut() {
        let title = String(repeating: "t", count: Proposal.titleLimit + 50)
        let proposal = parse(["title": title, "action": "a"])

        #expect(proposal?.title.count == Proposal.titleLimit)
        #expect(proposal?.title.hasSuffix("…") == true)
    }

    @Test("Line breaks, escapes, and direction overrides never reach the action")
    func actionIsCleaned() {
        let proposal = parse([
            "title": "t",
            "action": "Archive\u{202E} it\nnow\u{1B}[2J",
        ])

        #expect(proposal?.action == "Archive it now[2J")
    }

    @Test("A file missing its title or action, or naming an unknown status, is refused")
    func malformedFilesAreRefused() {
        #expect(parse(["action": "a"]) == nil)
        #expect(parse(["title": "t"]) == nil)
        #expect(parse(["title": "  \n ", "action": "a"]) == nil)
        #expect(parse(["title": "t", "action": "a", "status": "approved"]) == nil)
        #expect(parse(["title": "t", "action": "a", "status": 1]) == nil)
        #expect(Proposal.parse(Data("[1, 2]".utf8), id: "a", modified: modified) == nil)
    }

    @Test("Only a plain lowercase id names a proposal")
    func idsAreValidated() {
        for id in ["2026-11-15-cancel-foo", "a", String(repeating: "a", count: 64)] {
            #expect(Proposal.isValidID(id))
        }
        let tooLong = String(repeating: "a", count: 65)
        for id in ["", "-a", "A", "a/b", "../x", "a.json", "a\n", tooLong] {
            #expect(!Proposal.isValidID(id))
        }
        #expect(parse(["title": "t", "action": "a"], id: "../escape") == nil)
    }

    @Test("An offered rule and a claimed one are read; a rule too long to show is dropped")
    func standingFields() {
        let offered = parse([
            "title": "t",
            "action": "a",
            "standing": [
                "when": "Mail arrives\nfrom Maya Chen",
                "do": "Label the thread 'Reply today'",
                "because": "Approved four times, each for Maya.",
            ],
        ])
        #expect(offered?.standingOffer == StandingOffer(
            condition: "Mail arrives from Maya Chen",
            action: "Label the thread 'Reply today'",
            basis: "Approved four times, each for Maya."
        ))
        #expect(offered?.under == nil)

        // Either governing part too long to show whole drops the offer and keeps the proposal.
        // So does an offer that is not the two-part object: a bare sentence has no condition.
        let tooLong = String(repeating: "r", count: StandingRule.partLimit + 1)
        let unusable: [Any] = [
            ["when": tooLong, "do": "x"],
            ["when": "x", "do": tooLong],
            ["when": "x"],
            "Trash promotional mail.",
        ]
        for standing in unusable {
            let dropped = parse(["title": "t", "action": "a", "standing": standing])
            #expect(dropped != nil)
            #expect(dropped?.standingOffer == nil)
        }

        // The basis only informs the decision, so a long one is cut rather than refused.
        let longBasis = String(repeating: "b", count: StandingOffer.basisLimit + 50)
        let cut = parse([
            "title": "t",
            "action": "a",
            "standing": ["when": "x", "do": "y", "because": longBasis],
        ])
        #expect(cut?.standingOffer?.basis?.count == StandingOffer.basisLimit)

        let claimed = parse([
            "title": "t",
            "action": "a",
            "under": "s-0000abcd",
            "automatic": true,
            "decided": "2026-11-15T17:12:00Z",
        ])
        #expect(claimed?.under == "s-0000abcd")
        #expect(claimed?.isAutomatic == true)
        #expect(claimed?.decided == Date(timeIntervalSince1970: 1_794_762_720))

        #expect(parse(["title": "t", "action": "a", "under": "everything"])?.under == nil)
    }

    @Test("A file over the size cap is refused unread")
    func oversizedFileIsRefused() {
        let padding = String(repeating: "x", count: Proposal.maximumFileBytes)
        #expect(parse(["title": "t", "action": "a", "padding": padding]) == nil)
    }
}

@Suite("ProVisor queue")
struct ProposalQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func proposal(
        _ id: String,
        status: Proposal.Status = .proposed,
        createdAgo: TimeInterval = 0,
        expiresIn: TimeInterval? = nil,
        isCleared: Bool = false
    ) -> Proposal {
        Proposal(
            id: id,
            title: id,
            why: nil,
            action: "a",
            kind: nil,
            created: now.addingTimeInterval(-createdAgo),
            expires: expiresIn.map { now.addingTimeInterval($0) },
            status: status,
            result: nil,
            isCleared: isCleared
        )
    }

    @Test("Declined, withdrawn, expired, and cleared proposals leave the queue")
    func hidesWhatIsSettled() {
        let visible = ProposalQueue.visible([
            proposal("waiting"),
            proposal("dismissed", status: .dismissed),
            proposal("withdrawn", status: .withdrawn),
            proposal("expired", expiresIn: -60),
            proposal("not-yet-expired", expiresIn: 60),
            proposal("done", status: .done),
            proposal("cleared", status: .done, isCleared: true),
            proposal("failed", status: .failed),
        ], now: now)

        #expect(Set(visible.map(\.id)) == ["waiting", "not-yet-expired", "done", "failed"])
    }

    @Test("Something done under a standing approval shows for a day, then leaves by itself")
    func automaticRowsExpire() {
        var recent = proposal("recent", status: .done)
        recent.isAutomatic = true
        recent.decided = now.addingTimeInterval(-3600)

        var old = proposal("old", status: .done)
        old.isAutomatic = true
        old.decided = now.addingTimeInterval(-StandingApprovals.automaticRowLifetime - 1)

        var approvedByHand = proposal("by-hand", status: .done)
        approvedByHand.decided = old.decided

        let visible = ProposalQueue.visible([recent, old, approvedByHand], now: now)
        #expect(Set(visible.map(\.id)) == ["recent", "by-hand"])
    }

    @Test("Proposals awaiting a decision lead, newest first, and the id settles a tie")
    func ordering() {
        let visible = ProposalQueue.visible([
            proposal("done-new", status: .done, createdAgo: 0),
            proposal("b-old", createdAgo: 100),
            proposal("a-old", createdAgo: 100),
            proposal("failed-newer", status: .failed, createdAgo: 50),
            proposal("newest", createdAgo: 10),
        ], now: now)

        #expect(visible.map(\.id) == ["newest", "failed-newer", "a-old", "b-old", "done-new"])
    }
}

/// The access list is the boundary between an agent that reads and one that acts, so the rules
/// it will accept are the test.
@Suite("ProVisor access")
struct ProVisorAccessTests {
    private func parse(scout: [Any], act: [Any]) -> ProVisorAccess? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["scout": scout, "act": act]
        ) else { return nil }
        return ProVisorAccess.parse(data)
    }

    @Test("The shipped defaults parse, and the scout holds nothing that changes anything")
    func defaultsAreValid() throws {
        let access = try #require(
            ProVisorAccess.parse(Data(ProVisorAccess.defaultFileContents.utf8))
        )

        #expect(!access.scout.isEmpty)
        for rule in access.scout {
            let tool = rule.components(separatedBy: "__").last ?? ""
            #expect(["search_*", "get_*", "list_*"].contains(tool))
        }
        #expect(!access.act.contains { $0.contains("send") || $0.contains("reply") })
        // Nobody reviews a run under a standing approval, so its list is the narrowest: what
        // it may do is a subset of what an approved run may, and it cannot draft.
        #expect(!access.auto.isEmpty)
        #expect(Set(access.auto).isSubset(of: Set(access.act)))
        #expect(!access.auto.contains { $0.contains("draft") || $0.contains("send") })
    }

    @Test("Leaving the unreviewed list out switches standing approvals off")
    func autoListIsOptional() {
        #expect(parse(scout: ["mcp__a__get_*"], act: [])?.auto == [])

        let malformed = try? JSONSerialization.data(
            withJSONObject: ["scout": [String](), "act": [String](), "auto": ["Bash"]]
        )
        #expect(malformed.flatMap(ProVisorAccess.parse) == nil)
    }

    @Test("A rule names connector tools under a literal server, and nothing else")
    func ruleShapes() {
        for rule in [
            "mcp__claude_ai_Gmail__search_*",
            "mcp__claude_ai_Gmail__*",
            "mcp__claude_ai_Gmail__get_thread",
            "mcp__claude_ai_Notion__notion-search",
        ] {
            #expect(ProVisorAccess.isValidRule(rule))
        }
        for rule in [
            "Bash",
            "Edit(/proposals/**)",
            "*",
            "mcp__*",
            "mcp____search",
            "mcp__server__",
            "mcp__server__tool(arg)",
            "mcp__server__to*ol",
            "mcp__server name__tool",
            "mcp__server__tool\n",
        ] {
            #expect(!ProVisorAccess.isValidRule(rule))
        }
    }

    @Test("One malformed rule rejects the whole file")
    func listsAreAcceptedWhole() {
        #expect(parse(scout: ["mcp__a__get_*"], act: []) != nil)
        #expect(parse(scout: ["mcp__a__get_*", "Bash"], act: []) == nil)
        #expect(parse(scout: ["mcp__a__get_*"], act: ["mcp__a__send", 7]) == nil)
        #expect(ProVisorAccess.parse(Data(#"{"scout": []}"#.utf8)) == nil)
    }
}

@Suite("ProVisor command line")
struct ProVisorCommandTests {
    private let access = ProVisorAccess(
        scout: ["mcp__mail__get_*"],
        act: ["mcp__mail__create_draft"],
        auto: ["mcp__mail__trash_*"]
    )
    private let rule = StandingRule(
        id: "s-0000abcd",
        condition: "It is Tuesday",
        action: "Move promotional mail from senders they have not opened in 90 days to Trash",
        since: Date(timeIntervalSince1970: 0),
        revoked: nil
    )
    /// 09:12 on Sunday 15 November 2026 in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_794_762_720)
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let proposal = Proposal(
        id: "a",
        title: "Cancel Foo Pro",
        why: nil,
        action: "Draft the cancellation email.",
        kind: nil,
        created: Date(timeIntervalSince1970: 0),
        expires: nil,
        status: .proposed,
        result: nil,
        isCleared: false
    )

    /// The values following `flag`, up to the next flag.
    private func values(after flag: String, in arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: flag) else { return [] }
        return Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") })
    }

    @Test("A scout is confined, may write only its two folders, and holds no acting tool")
    func scoutArguments() {
        let arguments = ProVisorCommand.scoutArguments(
            brief: "BRIEF",
            access: access,
            standing: [],
            now: now,
            timeZone: losAngeles
        )

        #expect(arguments.contains("--restricted"))
        #expect(values(after: "--permission-prompts", in: arguments) == ["none"])
        #expect(values(after: "--tools", in: arguments) == ["Read,Write,Edit,Glob,Grep"])
        #expect(values(after: "--append-system-prompt", in: arguments) == ["BRIEF"])
        #expect(values(after: "--allowedTools", in: arguments) == [
            "Edit(/proposals/**)",
            "Edit(/memory/**)",
            "mcp__mail__get_*",
        ])
        // The prompt tells the scout what an approved action could use, by name.
        #expect(arguments[1].contains("mcp__mail__create_draft"))
        // A rule can turn on the weekday, so the scout is told it rather than left to derive it.
        #expect(arguments[1].contains("Sunday 2026-11-15 09:12"))
        #expect(arguments[1].contains("America/Los_Angeles"))
    }

    @Test("An acting run gains the acting tools, writes no files, and is told the action")
    func actArguments() {
        let arguments = ProVisorCommand.actArguments(proposal: proposal, access: access)

        #expect(arguments.contains("--restricted"))
        #expect(values(after: "--permission-prompts", in: arguments) == ["none"])
        #expect(values(after: "--allowedTools", in: arguments) == [
            "mcp__mail__get_*",
            "mcp__mail__create_draft",
        ])
        #expect(!arguments.contains("--append-system-prompt"))
        #expect(arguments[1].contains("Approved action: Draft the cancellation email."))
    }

    @Test("A run nobody reviewed gets the shorter tool list, and is told the rule it is under")
    func unreviewedActArguments() {
        let arguments = ProVisorCommand.actArguments(
            proposal: proposal,
            access: access,
            under: rule,
            now: now,
            timeZone: losAngeles
        )

        #expect(arguments.contains("--restricted"))
        #expect(values(after: "--permission-prompts", in: arguments) == ["none"])
        #expect(values(after: "--allowedTools", in: arguments) == [
            "mcp__mail__get_*",
            "mcp__mail__trash_*",
        ])
        #expect(!arguments.contains("mcp__mail__create_draft"))
        #expect(arguments[1].contains("When: It is Tuesday"))
        #expect(arguments[1].contains("Do: Move promotional mail"))
        // The run checks the condition for itself, so it needs the weekday too.
        #expect(arguments[1].contains("Sunday 2026-11-15 09:12"))
        #expect(arguments[1].contains("Nobody has reviewed"))
    }

    @Test("A scout is told the rules in force by id, the ones taken back, and the tool list")
    func standingBriefing() {
        var revoked = StandingRule(
            id: "s-0000beef",
            condition: "A receipt arrives",
            action: "Label it 'Receipts'",
            since: Date(timeIntervalSince1970: 0),
            revoked: nil
        )
        revoked.revoked = Date(timeIntervalSince1970: 10)

        let briefing = ProVisorCommand.standingBriefing(rules: [rule, revoked], access: access)
        #expect(briefing.contains(#"[s-0000abcd] when "It is Tuesday", do "Move promotional"#))
        #expect(briefing.contains(#"Revoked, never to be acted on or offered again: when "A rec"#))
        #expect(!briefing.contains("[s-0000beef]"))
        #expect(briefing.contains("mcp__mail__trash_*"))

        let none = ProVisorCommand.standingBriefing(rules: [], access: access)
        #expect(none.contains("No standing approvals are in force yet."))

        let off = ProVisorCommand.standingBriefing(
            rules: [rule],
            access: ProVisorAccess(scout: [], act: [])
        )
        #expect(off.contains("switched off"))
        #expect(!off.contains("s-0000abcd"))
    }
}

@Suite("ProVisor schedule")
struct ProVisorScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("With no pass on record the first one waits only for things to settle")
    func firstPass() {
        let delay = ProVisorSchedule.delay(
            lastScout: nil,
            lastAttempt: nil,
            intervalHours: 6,
            now: now
        )
        #expect(delay == ProVisorSchedule.settleDelay)
    }

    @Test("The next pass is due one interval after the last one finished")
    func interval() {
        let delay = ProVisorSchedule.delay(
            lastScout: now.addingTimeInterval(-3600),
            lastAttempt: now.addingTimeInterval(-3700),
            intervalHours: 6,
            now: now
        )
        #expect(delay == 5 * 3600)
    }

    @Test("A time is written for the agent with its weekday, in the user's zone")
    func localStamp() {
        let instant = Date(timeIntervalSince1970: 1_794_762_720)  // 2026-11-15T17:12:00Z
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        let west = ProVisorClock.localStamp(instant, timeZone: losAngeles)
        let east = ProVisorClock.localStamp(instant, timeZone: tokyo)
        #expect(west == "Sunday 2026-11-15 09:12")
        // The same instant is already Monday further east: the weekday is the user's, not UTC's.
        #expect(east == "Monday 2026-11-16 02:12")
    }

    @Test("An overdue pass that just failed backs off instead of repeating")
    func failureBacksOff() {
        let delay = ProVisorSchedule.delay(
            lastScout: now.addingTimeInterval(-10 * 3600),
            lastAttempt: now.addingTimeInterval(-60),
            intervalHours: 6,
            now: now
        )
        #expect(delay == ProVisorSchedule.retryDelay - 60)
    }
}

@Suite("ProVisor proposal store")
struct ProposalStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provisor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ fields: [String: Any], named name: String, in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: fields)
        try data.write(to: directory.appendingPathComponent(name))
    }

    @Test("Only regular proposal files load, and a link is never followed")
    func loadsOnlyRegularProposalFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write(["title": "Real", "action": "a"], named: "real.json", in: directory)
        try write(["title": "Notes", "action": "a"], named: "notes.txt", in: directory)
        try write(["title": "Bad id", "action": "a"], named: "Bad Name.json", in: directory)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.json"),
            withDestinationURL: directory.appendingPathComponent("real.json")
        )

        #expect(ProposalStore.load(from: directory).map(\.id) == ["real"])
    }

    @Test("A decision is written into the file without disturbing what the agent wrote")
    func recordsDecision() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            ["title": "Real", "action": "a", "kind": "reply-owed", "agentNote": "kept"],
            named: "real.json",
            in: directory
        )

        try ProposalStore.record(id: "real", in: directory, status: .dismissed)

        let loaded = try #require(ProposalStore.load(from: directory).first)
        #expect(loaded.status == .dismissed)
        #expect(loaded.title == "Real")
        #expect(loaded.kind == "reply-owed")

        let data = try Data(contentsOf: directory.appendingPathComponent("real.json"))
        let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["agentNote"] as? String == "kept")
        #expect(fields["decided"] is String)
    }

    @Test("Clearing a finished proposal keeps it marked as done")
    func clearingKeepsStatus() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(["title": "Real", "action": "a"], named: "real.json", in: directory)

        try ProposalStore.record(id: "real", in: directory, status: .done, result: "Drafted.")
        try ProposalStore.record(id: "real", in: directory, cleared: true)

        let loaded = try #require(ProposalStore.load(from: directory).first)
        #expect(loaded.status == .done)
        #expect(loaded.result == "Drafted.")
        #expect(loaded.isCleared)
    }

    @Test("The answer to an offered rule, and that something ran unasked, are written back")
    func recordsStandingAnswers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            [
                "title": "Real",
                "action": "a",
                "standing": ["when": "It is Tuesday", "do": "Trash unopened promos"],
            ],
            named: "real.json",
            in: directory
        )

        try ProposalStore.record(id: "real", in: directory, standingDecision: "declined")
        try ProposalStore.record(
            id: "real",
            in: directory,
            status: .done,
            automatic: true,
            now: Date(timeIntervalSince1970: 1_794_762_720),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )

        let data = try Data(contentsOf: directory.appendingPathComponent("real.json"))
        let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["standingDecision"] as? String == "declined")
        #expect((fields["standing"] as? [String: String])?["when"] == "It is Tuesday")
        // The weekday is spelled out for the agent: a pattern in *when* things are approved is
        // one it is asked to find.
        #expect(fields["decidedLocal"] as? String == "Sunday 2026-11-15 09:12")

        let loaded = try #require(ProposalStore.load(from: directory).first)
        #expect(loaded.isAutomatic)
        #expect(loaded.decided != nil)
    }

    @Test("A decision cannot be aimed outside the proposals folder")
    func recordRefusesForeignIDs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try ProposalStore.record(id: "../escape", in: directory, status: .dismissed)
        }
    }
}

/// A standing approval lets something run that nobody looked at first, so what is under test
/// is how little a claim to be under one is worth on its own.
@Suite("ProVisor standing approvals")
struct StandingApprovalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let offer = StandingOffer(
        condition: "Mail arrives from Maya Chen",
        action: "Label the thread 'Reply today'",
        basis: "Approved four times, each for Maya."
    )

    private func rule(_ id: String, revoked: Bool = false) -> StandingRule {
        StandingRule(
            id: id,
            condition: offer.condition,
            action: offer.action,
            since: now,
            revoked: revoked ? now : nil
        )
    }

    private func proposal(
        under: String?,
        status: Proposal.Status = .proposed,
        expiresIn: TimeInterval? = nil
    ) -> Proposal {
        var proposal = Proposal(
            id: "p",
            title: "t",
            why: nil,
            action: "a",
            kind: nil,
            created: now,
            expires: expiresIn.map { now.addingTimeInterval($0) },
            status: status,
            result: nil,
            isCleared: false
        )
        proposal.under = under
        return proposal
    }

    @Test("A claim counts only when it names a rule in force, on a proposal still waiting")
    func claimNeedsARuleInForce() {
        let rules = [rule("s-0000aaaa"), rule("s-0000bbbb", revoked: true)]
        func admitted(_ proposal: Proposal) -> String? {
            StandingApprovals.rule(for: proposal, in: rules, now: now)?.id
        }

        #expect(admitted(proposal(under: "s-0000aaaa")) == "s-0000aaaa")
        #expect(admitted(proposal(under: nil)) == nil)
        #expect(admitted(proposal(under: "s-0000bbbb")) == nil)
        #expect(admitted(proposal(under: "s-0000cccc")) == nil)
        #expect(admitted(proposal(under: "s-0000aaaa", status: .failed)) == nil)
        #expect(admitted(proposal(under: "s-0000aaaa", status: .done)) == nil)
        #expect(admitted(proposal(under: "s-0000aaaa", expiresIn: -1)) == nil)
        #expect(admitted(proposal(under: "s-0000aaaa", expiresIn: 60)) == "s-0000aaaa")
    }

    @Test("A rule is added once, cleaned, and never from a part too long to have been shown")
    func adding() {
        let messy = StandingOffer(
            condition: "It is\nTuesday",
            action: "Trash promos \u{202E}now",
            basis: nil
        )
        let added = StandingApprovals.rule(adding: messy, to: [], now: now, id: "s-0000aaaa")
        #expect(added?.condition == "It is Tuesday")
        #expect(added?.action == "Trash promos now")
        #expect(added?.isActive == true)

        let existing = [rule("s-0000aaaa")]
        #expect(StandingApprovals.rule(adding: offer, to: existing, now: now) == nil)

        // The same action under a different condition is a different rule.
        let onTuesdays = StandingOffer(
            condition: "It is Tuesday",
            action: offer.action,
            basis: nil
        )
        #expect(StandingApprovals.rule(adding: onTuesdays, to: existing, now: now) != nil)

        // A rule that was taken back can be granted afresh; it is a new rule with a new id.
        let revoked = [rule("s-0000aaaa", revoked: true)]
        #expect(StandingApprovals.rule(adding: offer, to: revoked, now: now) != nil)

        let tooLong = String(repeating: "r", count: StandingRule.partLimit + 1)
        let overlong = StandingOffer(condition: tooLong, action: "x", basis: nil)
        let blank = StandingOffer(condition: "x", action: "  ", basis: nil)
        #expect(StandingApprovals.rule(adding: overlong, to: [], now: now) == nil)
        #expect(StandingApprovals.rule(adding: blank, to: [], now: now) == nil)
        #expect(StandingApprovals.rule(adding: offer, to: [], now: now, id: "bad id") == nil)
    }

    @Test("Revoking keeps the rule on file, out of force")
    func revoking() {
        let rules = StandingApprovals.revoking("s-0000aaaa", in: [rule("s-0000aaaa")], now: now)

        #expect(rules.count == 1)
        #expect(rules.first?.isActive == false)
        #expect(rules.first?.revoked == now)
        #expect(StandingApprovals.revoking("s-0000ffff", in: rules, now: now) == rules)
    }

    @Test("Generated ids are well formed")
    func ids() {
        for _ in 0..<50 {
            #expect(StandingRule.isValidID(StandingApprovals.newID()))
        }
        let malformed = ["", "s-", "s-0000AAAA", "s-0000aaa", "s-0000aaaaa", "x-0000aaaa"]
        for id in malformed + ["s-0000aaaa\n"] {
            #expect(!StandingRule.isValidID(id))
        }
    }

    @Test("Rules survive a save and a load; a malformed entry only ever withholds a rule")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provisor-standing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(StandingApprovals.load(from: url).isEmpty)

        let saved = [rule("s-0000aaaa"), rule("s-0000bbbb", revoked: true)]
        try StandingApprovals.save(saved, to: url)
        #expect(StandingApprovals.load(from: url) == saved)

        let handEdited = Data(#"""
        {"rules": [
          {"id": "s-0000aaaa", "when": "It is Tuesday", "do": "File receipts",
           "since": "2026-11-15T17:12:00Z"},
          {"id": "not-an-id", "when": "Always", "do": "Do anything"},
          {"id": "s-0000aaaa", "when": "Reusing an id", "do": "Should not load"},
          {"id": "s-0000cccc", "do": "No condition"},
          {"id": "s-0000dddd", "rule": "A one-sentence rule from before conditions"},
          "junk"
        ]}
        """#.utf8)
        let parsed = StandingApprovals.parse(handEdited)
        #expect(parsed.map(\.id) == ["s-0000aaaa"])
        #expect(parsed.first?.condition == "It is Tuesday")
        #expect(parsed.first?.action == "File receipts")
        #expect(parsed.first?.since == Date(timeIntervalSince1970: 1_794_762_720))
        #expect(StandingApprovals.parse(Data("[]".utf8)).isEmpty)
    }
}

@MainActor
@Suite("ProVisor settings")
struct ProVisorSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "provisor-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("ProVisor stays off until turned on; other modules default on")
    func moduleIsOptIn() {
        let settings = SettingsStore(defaults: makeDefaults())

        #expect(!settings.isEnabled("provisor"))
        #expect(settings.isEnabled("media"))

        settings.registerModuleIfNeeded("provisor")
        settings.registerModuleIfNeeded("media")
        #expect(!settings.isEnabled("provisor"))
        #expect(settings.isEnabled("media"))

        settings.setEnabled(true, for: "provisor")
        #expect(settings.isEnabled("provisor"))
    }

    @Test("The cadence defaults to six hours, and manual-only survives a relaunch")
    func cadence() {
        let defaults = makeDefaults()
        #expect(SettingsStore(defaults: defaults).provisorScoutHours == 6)

        SettingsStore(defaults: defaults).provisorScoutHours = 0
        #expect(SettingsStore(defaults: defaults).provisorScoutHours == 0)

        defaults.set(5, forKey: "provisor.scoutHours")
        #expect(SettingsStore(defaults: defaults).provisorScoutHours == 6)
    }
}
