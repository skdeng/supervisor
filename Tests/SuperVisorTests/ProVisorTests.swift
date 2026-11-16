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
        act: ["mcp__mail__create_draft"]
    )

    /// The values following `flag`, up to the next flag.
    private func values(after flag: String, in arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: flag) else { return [] }
        return Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") })
    }

    @Test("A scout is confined, may write only its two folders, and holds no acting tool")
    func scoutArguments() {
        let arguments = ProVisorCommand.scoutArguments(
            charter: "BRIEF",
            access: access,
            now: Date(timeIntervalSince1970: 1_794_762_720),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
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
        #expect(arguments[1].contains("America/Los_Angeles"))
    }

    @Test("An acting run gains the acting tools, writes no files, and is told the action")
    func actArguments() {
        let proposal = Proposal(
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

    @Test("A decision cannot be aimed outside the proposals folder")
    func recordRefusesForeignIDs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try ProposalStore.record(id: "../escape", in: directory, status: .dismissed)
        }
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
