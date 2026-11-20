import Foundation

/// One way to act on a proposal: a short name for its chip on the review screen, and the action
/// an approval of it runs.
struct ProposalOption: Equatable, Sendable {
    let label: String
    /// Shown to the user in full, then handed to the acting run.
    let action: String
}

/// What the user chose to have carried out on a proposal.
enum ProposalChoice: Equatable, Sendable {
    /// One of the proposal's own options, by its position in `Proposal.options`.
    case option(Int)
    /// An instruction the user typed themselves.
    case instruction(String)
}

/// One thing the scouting agent thinks the user would want done, read from a JSON file the
/// agent wrote into its workspace.
///
/// Every field is model-generated text shaped by whatever the agent read — mail from anyone
/// who can send some — so a file is parsed defensively and its text is bounded and cleaned
/// before it reaches a view or a prompt.
struct Proposal: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        /// Waiting for the user's decision.
        case proposed
        /// Approved and carried out.
        case done
        /// Approved, but the acting run could not carry it out; `result` says why.
        case failed
        /// The user did not want it.
        case dismissed
        /// The agent took it back because it stopped being true.
        case withdrawn
    }

    /// The file's name without its extension.
    let id: String
    let title: String
    let why: String?
    /// The ways to act on it, never empty. The first is the one the agent recommends.
    let options: [ProposalOption]
    let kind: String?
    let created: Date
    let expires: Date?
    let status: Status
    /// What the acting run reported, or why it failed.
    let result: String?
    /// Whether a finished proposal has no row: the user cleared it, the run that carried it
    /// out said nothing is left for them to see (`ActionReport`), or their own sign-in settled
    /// it. The status stays `done`, so the agent still reads the proposal as one that was wanted.
    let isCleared: Bool
    /// A rule the agent offers to make standing: when this holds, do that, from now on without
    /// asking. Shown in full beside the action; it becomes a rule only if the user says so.
    var standingOffer: StandingOffer?
    /// The standing approval the agent says this falls under. It is a claim, not a grant:
    /// `StandingApprovals.rule(for:in:now:)` decides whether a rule in force matches it.
    var under: String?
    /// Whether it was carried out under a standing approval rather than on a tap.
    var isAutomatic = false
    /// When the user, or a standing approval, settled it.
    var decided: Date?
    /// What the user last had carried out, as recorded in the file. It is read for display
    /// only: a run is instructed from the choice captured at the tap.
    var choice: ProposalChoice?
    /// The host of a site the agent asks the user to sign in to. It is the agent's word, shaped
    /// by mail: it offers a sign-in and never grants one, and the sign-in window opens it only
    /// when the user's own browsers know it (`SiteSignInModel`).
    var site: String?
    /// When the person took it into a session they direct (`Handoff`), as the file says. It
    /// is read for the review window's caption alone; `HandoffLedger` is the app's record.
    var handedOff: Date?

    /// The `kind` of a proposal about ProVisor itself: something that got in its way, or a
    /// change to its code, its protocol, or the charter that would let it do more.
    static let improvementKind = "improve"

    /// Whether this is a proposal about ProVisor itself. Nothing an acting run holds can carry
    /// one out, so it is never approved, typed over, or admitted under a standing approval:
    /// the person takes it into a session of their own (`Handoff.Workplace.source`). The kind
    /// is the agent's word, shaped by mail, and it buys only that: a different folder for a
    /// session the person directs.
    var isImprovement: Bool { kind == Self.improvementKind }

    /// Whether the proposal still awaits a decision — a failed one can be approved again.
    var isOpen: Bool { status == .proposed || status == .failed }

    var recommended: ProposalOption { options[0] }

    /// The action to show for a proposal that has been decided: the recorded choice, or the
    /// recommended option where none is recorded.
    ///
    /// For display only. The choice is read from a file the scout can rewrite, so no run is
    /// ever built from this and the review screen never offers it for approval.
    var recordedAction: String {
        switch choice {
        case let .instruction(text): text
        case let .option(index) where options.indices.contains(index): options[index].action
        case .option, nil: recommended.action
        }
    }
}

extension Proposal {
    static let maximumFileBytes = 32 << 10
    /// Room kept in a file that can still be decided, for what a decision writes into it: the
    /// status and its dates, a result, and a typed instruction at four bytes a character.
    static let decisionHeadroomBytes = 6 << 10
    static let titleLimit = 100
    static let whyLimit = 400
    static let actionLimit = 600
    static let resultLimit = 400
    static let maximumOptions = 3
    static let optionLabelLimit = 24
    /// The chip name of a proposal written with a single `action`.
    static let singleOptionLabel = "Suggested"

    /// Anchored with `\A` and `\z`: ICU's `$` also matches before a trailing line terminator.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"\A[a-z0-9][a-z0-9-]{0,63}\z"#, options: .regularExpression) != nil
    }

    /// Reads one proposal file. `modified` stands in for a missing or unreadable `created`.
    static func parse(_ data: Data, id: String, modified: Date) -> Proposal? {
        guard isValidID(id),
              data.count <= maximumFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let title = displayText(fields["title"], limit: titleLimit),
              let options = parsedOptions(fields)
        else { return nil }

        let status: Status
        if let stored = fields["status"] {
            guard let name = stored as? String, let known = Status(rawValue: name) else {
                return nil
            }
            status = known
        } else {
            status = .proposed
        }
        // A decision is written back by re-encoding the whole file, which can come out larger
        // than the agent wrote it. A file that would then leave no room for the decision is
        // refused now: once approved, its outcome could not be recorded, and it would stay in
        // the queue to be approved and carried out again.
        if status == .proposed || status == .failed {
            guard let rewritten = try? JSONSerialization.data(
                withJSONObject: fields,
                options: ProposalStore.writingOptions
            ), rewritten.count + decisionHeadroomBytes <= maximumFileBytes else { return nil }
        }

        return Proposal(
            id: id,
            title: title,
            why: displayText(fields["why"], limit: whyLimit),
            options: options,
            kind: slug(fields["kind"]),
            created: date(fields["created"]) ?? modified,
            expires: date(fields["expires"]),
            status: status,
            result: displayText(fields["result"], limit: resultLimit),
            isCleared: fields["cleared"] as? Bool ?? false,
            // Like the action, an offered rule is never shortened to fit: one that cannot be
            // shown whole is dropped, and the proposal stays an ordinary one.
            standingOffer: StandingOffer.parse(fields["standing"]),
            under: (fields["under"] as? String).flatMap { StandingRule.isValidID($0) ? $0 : nil },
            isAutomatic: fields["automatic"] as? Bool ?? false,
            decided: date(fields["decided"]),
            choice: parsedChoice(fields, optionCount: options.count),
            site: parsedSite(fields["site"]),
            handedOff: date(fields["handedOff"])
        )
    }

    /// The `site` field lowercased, when it is a plain host name; nil otherwise. A bad value
    /// drops the field and keeps the proposal. Only ASCII is lowercased: Unicode case mapping
    /// would turn a look-alike such as the Kelvin sign into a real letter.
    static func parsedSite(_ value: Any?) -> String? {
        guard let text = value as? String,
              text.utf8.count <= 253,
              text.unicodeScalars.allSatisfy(\.isASCII)
        else { return nil }
        let host = text.lowercased()
        return SiteHost.isValid(host) ? host : nil
    }

    /// The proposal's options: the `options` list when the file has one, else its single
    /// `action`. A file carrying both is rejected, since it does not say which the user would
    /// be approving.
    ///
    /// An action is what an approval runs, so it is never shortened to fit: text the user could
    /// not read in full is text they did not approve. One unusable entry rejects the whole
    /// list, since a proposal missing an option the agent meant to offer reads as a different
    /// proposal.
    private static func parsedOptions(_ fields: [String: Any]) -> [ProposalOption]? {
        guard let stored = fields["options"] else {
            return displayText(fields["action"], limit: actionLimit, truncates: false)
                .map { [ProposalOption(label: singleOptionLabel, action: $0)] }
        }
        guard fields["action"] == nil,
              let entries = stored as? [[String: Any]],
              (1...maximumOptions).contains(entries.count)
        else { return nil }

        var options: [ProposalOption] = []
        for entry in entries {
            guard let label = displayText(entry["label"], limit: optionLabelLimit, truncates: false),
                  let action = displayText(entry["action"], limit: actionLimit, truncates: false),
                  // Two chips with one name cannot be told apart.
                  !options.contains(where: { $0.label == label })
            else { return nil }
            options.append(ProposalOption(label: label, action: action))
        }
        return options
    }

    private static func parsedChoice(
        _ fields: [String: Any],
        optionCount: Int
    ) -> ProposalChoice? {
        if let text = typedText(fields["instructed"], limit: actionLimit) {
            return .instruction(text)
        }
        guard let number = fields["chose"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let position = Int(exactly: number.doubleValue),
              (1...optionCount).contains(position)
        else { return nil }
        return .option(position - 1)
    }

    /// Collapses whitespace and strips control and format characters. A newline or an ANSI
    /// escape in model-generated text would redraw a row, and a bidirectional override would
    /// let an action display as something other than what it says.
    ///
    /// Text past `limit` is cut with an ellipsis, or rejected outright when `truncates` is false.
    static func displayText(_ value: Any?, limit: Int, truncates: Bool = true) -> String? {
        guard let text = value as? String else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let cleaned = collapsed.filter { character in
            character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > limit else { return cleaned }
        return truncates ? String(cleaned.prefix(limit - 1)) + "…" : nil
    }

    /// Cleans text the user typed themselves: whitespace is collapsed, and control characters
    /// and the bidirectional embedding, override, and isolate marks are removed. Everything
    /// else is kept as typed — a joiner inside an emoji or a script is part of what they wrote.
    /// Nil when nothing is left or the text runs past `limit`; it is never shortened.
    static func typedText(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let isDirectional = (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
            if isDirectional { continue }
            if scalar.properties.generalCategory == .control {
                // A line break or a tab separates words; any other control character goes.
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    scalars.append(" ")
                }
                continue
            }
            scalars.append(scalar)
        }
        let cleaned = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty, cleaned.count <= limit else { return nil }
        return cleaned
    }

    private static func slug(_ value: Any?) -> String? {
        guard let text = value as? String,
              text.range(of: #"\A[a-z0-9][a-z0-9-]{0,39}\z"#, options: .regularExpression) != nil
        else { return nil }
        return text
    }

    /// An ISO 8601 time, with or without fractional seconds; nil for anything else.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.count <= 40 else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// How the sheet arranges proposals.
enum ProposalQueue {
    /// How many proposals get a row unprompted; the rest fold behind a count.
    static let leadCount = 3

    /// The proposals worth a row: those awaiting a decision and not yet expired, then those
    /// carried out whose result the person still needs to see. A finished proposal has a row
    /// only when its run asked for one (`ActionReport`), until the user clears it. One kept
    /// under a standing approval leaves by itself after a day — rows that had to be cleared by
    /// hand would turn "stop asking me" into a different chore. Within each group
    /// the newest leads, and the id settles a tie so a reload never reshuffles the rows. Of
    /// several open requests for one site, only the first is shown (`repeatedSiteRequests`).
    static func visible(_ proposals: [Proposal], now: Date) -> [Proposal] {
        let repeated = repeatedSiteRequests(in: proposals, now: now)
        return proposals
            .filter { !repeated.contains($0.id) }
            .filter { proposal in
                switch proposal.status {
                case .proposed, .failed:
                    guard let expires = proposal.expires else { return true }
                    return expires > now
                case .done:
                    guard !proposal.isCleared else { return false }
                    guard proposal.isAutomatic else { return true }
                    let settled = proposal.decided ?? proposal.created
                    return now.timeIntervalSince(settled) < StandingApprovals.automaticRowLifetime
                case .dismissed, .withdrawn:
                    return false
                }
            }
            .sorted { first, second in
                if first.isOpen != second.isOpen { return first.isOpen }
                if first.created != second.created { return first.created > second.created }
                return first.id < second.id
            }
    }

    /// The ids of open, unexpired proposals asking for a site that an earlier open, unexpired
    /// proposal already asks for. The earliest created asks, the id settling a tie; the rest
    /// stay on file and are neither shown nor announced, since one sign-in answers them all.
    static func repeatedSiteRequests(in proposals: [Proposal], now: Date) -> Set<String> {
        let asking = proposals
            .filter { $0.isOpen && $0.site != nil && !ProposalReview.isExpired($0, now: now) }
            .sorted { first, second in
                if first.created != second.created { return first.created < second.created }
                return first.id < second.id
            }
        var asked = Set<String>()
        var repeated = Set<String>()
        for proposal in asking {
            guard let site = proposal.site else { continue }
            if !asked.insert(site).inserted { repeated.insert(proposal.id) }
        }
        return repeated
    }
}

/// Keeps count of which proposals the user has been told about, so each is announced once
/// however many runs finish while it waits. A scouting pass and a reviewed run can overlap.
struct ProposalAnnouncer {
    /// Every proposal that has been on file at a seeding or a count, less those held back. Nil
    /// until seeded.
    private var seen: Set<String>?
    /// Proposals left out of a count because their request's host was still being looked up,
    /// waiting for `countReleased`.
    private var heldBack: Set<String> = []

    /// Takes what is on file at the first read after a start as already known, so proposals
    /// that were waiting at launch are never announced as new.
    mutating func seedIfNeeded(with loaded: [Proposal]) {
        if seen == nil {
            seen = Set(loaded.map(\.id))
        }
    }

    /// How many proposals in `loaded` are news: those awaiting a decision that were neither
    /// on file before nor admitted under a standing approval. Something admitted under a rule
    /// is being dealt with, which is the point of having given one. A repeated request for a
    /// site already asked for is not news either (`ProposalQueue.repeatedSiteRequests`), nor is
    /// a request that a sign-in prompt announces in its own right (`covered`,
    /// `SignInDemand.coveredProposalIDs`).
    ///
    /// A request in `awaitingRecognition` is neither counted nor seen: whether it is a sign-in
    /// prompt or an idea is not known yet, and `countReleased` counts it once it is. Every
    /// other proposal in `loaded` is seen afterwards, counted or not.
    mutating func countNew(
        in loaded: [Proposal],
        automatic: Set<String>,
        covered: Set<String> = [],
        awaitingRecognition: Set<String> = [],
        now: Date = Date()
    ) -> Int {
        let known = seen ?? []
        return admit(
            loaded.filter { !known.contains($0.id) },
            from: loaded,
            automatic: automatic,
            covered: covered,
            awaitingRecognition: awaitingRecognition,
            now: now
        )
    }

    /// How many of the proposals `countNew` held back are news, now that their host is no
    /// longer in `awaitingRecognition`, by the same rules. One still awaiting stays held back,
    /// and one no longer on file is forgotten. Nothing is news before the announcer is seeded.
    mutating func countReleased(
        in loaded: [Proposal],
        automatic: Set<String>,
        covered: Set<String>,
        awaitingRecognition: Set<String>,
        now: Date = Date()
    ) -> Int {
        heldBack.formIntersection(loaded.map(\.id))
        guard seen != nil, !heldBack.isEmpty else { return 0 }
        return admit(
            loaded.filter { heldBack.contains($0.id) },
            from: loaded,
            automatic: automatic,
            covered: covered,
            awaitingRecognition: awaitingRecognition,
            now: now
        )
    }

    /// Marks `candidates` seen and counts the news among them, holding back those awaiting
    /// recognition.
    private mutating func admit(
        _ candidates: [Proposal],
        from loaded: [Proposal],
        automatic: Set<String>,
        covered: Set<String>,
        awaitingRecognition: Set<String>,
        now: Date
    ) -> Int {
        let repeated = ProposalQueue.repeatedSiteRequests(in: loaded, now: now)
        var known = seen ?? []
        var added = 0
        for proposal in candidates {
            if awaitingRecognition.contains(proposal.id) {
                heldBack.insert(proposal.id)
                continue
            }
            heldBack.remove(proposal.id)
            known.insert(proposal.id)
            if proposal.status == .proposed,
               !automatic.contains(proposal.id),
               !repeated.contains(proposal.id),
               !covered.contains(proposal.id)
            {
                added += 1
            }
        }
        seen = known
        return added
    }
}

/// Brings the items a reviewed run raised into the proposal queue.
///
/// A reviewed run holds acting tools and has been reading mail, so it is given no way to write
/// in `proposals/`. What it leaves in `raised/` is copied in here: under an id this code makes
/// up, keeping only the fields a proposal is written with, and never over a file that exists.
/// A raised item therefore cannot replace or alter a proposal, set its own status, or claim a
/// standing approval; it joins the queue as an ordinary proposal awaiting a tap.
enum RaisedItems {
    /// The most items taken from one sweep. The rest are discarded with the folder's contents.
    static let maximumPerSweep = 3

    /// The fields a raised item may carry into the queue. `standing` and `under` are left
    /// behind with everything the app writes: a reviewed run is never told the rules in force,
    /// so neither can be meant.
    static let carriedFields: Set<String> = [
        "title", "why", "action", "options", "kind", "created", "expires", "site",
    ]

    /// Moves every usable item into `proposals` and empties `raised`. Returns how many joined
    /// the queue.
    @discardableResult
    static func admit(
        from raised: URL,
        into proposals: URL,
        now: Date = Date(),
        suffix: () -> String = { String(UUID().uuidString.lowercased().prefix(8)) }
    ) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: raised,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let day = now.formatted(.iso8601.year().month().day())
        var admitted = 0
        for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true
            else { continue }
            // Whatever a regular file held, it is dealt with once and does not wait in the
            // folder to be read again.
            defer {
                if values.isRegularFile == true {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            guard values.isRegularFile == true,
                  url.pathExtension == "json",
                  admitted < maximumPerSweep,
                  let size = values.fileSize,
                  size > 0,
                  size <= Proposal.maximumFileBytes,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let fields = object as? [String: Any]
            else { continue }

            let carried = fields.filter { carriedFields.contains($0.key) }
            let id = "\(day)-raised-\(suffix())"
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: carried,
                options: ProposalStore.writingOptions
            ), Proposal.parse(encoded, id: id, modified: now) != nil else { continue }

            let destination = proposals.appendingPathComponent("\(id).json", isDirectory: false)
            do {
                try encoded.write(to: destination, options: .withoutOverwriting)
                admitted += 1
            } catch {
                continue
            }
        }
        return admitted
    }
}

/// Reads the agent's proposal files and writes the user's decisions back into them.
enum ProposalStore {
    /// How a file is encoded when a decision is written into it. Slashes stay unescaped: a
    /// proposal is full of links and addresses, and escaping each would grow the file.
    static let writingOptions: JSONSerialization.WritingOptions = [
        .prettyPrinted,
        .sortedKeys,
        .withoutEscapingSlashes,
    ]

    /// The most files read in one pass, newest first.
    static let maximumFiles = 400

    /// Loads every valid proposal among the direct, regular, non-symlink `.json` children of
    /// `directory`. A file that fails validation is skipped, never repaired.
    static func load(from directory: URL) -> [Proposal] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, modified: Date)] = []
        for url in children where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= Proposal.maximumFileBytes
            else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.modified > $1.modified }

        return candidates.prefix(maximumFiles).compactMap { candidate in
            guard let data = try? Data(contentsOf: candidate.url) else { return nil }
            return Proposal.parse(
                data,
                id: candidate.url.deletingPathExtension().lastPathComponent,
                modified: candidate.modified
            )
        }
    }

    /// Rewrites one proposal file with a decision or an outcome, keeping every field the agent
    /// wrote. The agent reads these back on its next pass; they are how it learns what the
    /// user wants.
    static func record(
        id: String,
        in directory: URL,
        status: Proposal.Status? = nil,
        result: String? = nil,
        cleared: Bool? = nil,
        standingDecision: String? = nil,
        automatic: Bool? = nil,
        choice: ProposalChoice? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws {
        var fields = try readFields(id: id, in: directory)
        if let status {
            stamp(status, into: &fields, now: now, timeZone: timeZone)
        }
        if let result {
            fields["result"] = result
        }
        if let cleared {
            fields["cleared"] = cleared
        }
        if let standingDecision {
            fields["standingDecision"] = standingDecision
        }
        if let automatic {
            fields["automatic"] = automatic
        }
        // An option is recorded by its position counted from one, the way the agent's brief
        // refers to it, and each kind of choice clears the other.
        switch choice {
        case let .option(index):
            fields["chose"] = index + 1
            fields["instructed"] = nil
        case let .instruction(text):
            fields["instructed"] = text
            fields["chose"] = nil
        case nil:
            break
        }

        try write(fields, id: id, in: directory)
    }

    /// Records a proposal carried out, with what its run reported. `cleared` is written either
    /// way, so the run's word on whether the result is shown stands over whatever the file held.
    static func recordCarriedOut(
        id: String,
        in directory: URL,
        report: ActionReport,
        automatic: Bool,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws {
        try record(
            id: id,
            in: directory,
            status: .done,
            result: Proposal.displayText(report.result, limit: Proposal.resultLimit)
                ?? ActionReport.emptyResult,
            cleared: !report.needsNotice,
            automatic: automatic ? true : nil,
            now: now,
            timeZone: timeZone
        )
    }

    /// Why a site request was, or was not, settled.
    enum SiteRequestSettlement: Equatable {
        case settled
        /// On disk the proposal is settled, dismissed, or withdrawn.
        case notOpen
        /// On disk the proposal names another site, or none.
        case siteChanged
    }

    /// Records a site request done with `result`, and cleared, as a compare-and-set against the
    /// file: only when the proposal on disk is `proposed` or `failed` and its `site`, read the
    /// way `Proposal.parse` reads it, is `host`. Otherwise nothing is written. What decides is
    /// the file, never a copy held in memory, since the agent can rewrite or settle it at any
    /// time.
    static func settleSiteRequest(
        id: String,
        in directory: URL,
        host: String,
        result: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> SiteRequestSettlement {
        var fields = try readFields(id: id, in: directory)
        let status: Proposal.Status? = switch fields["status"] {
        case nil: .proposed
        case let name as String: Proposal.Status(rawValue: name)
        default: nil
        }
        guard status == .proposed || status == .failed else { return .notOpen }
        guard Proposal.parsedSite(fields["site"]) == host else { return .siteChanged }
        stamp(.done, into: &fields, now: now, timeZone: timeZone)
        fields["result"] = result
        fields["cleared"] = true
        try write(fields, id: id, in: directory)
        return .settled
    }

    /// The result recorded on a proposal whose work the person finished in a session they
    /// directed.
    static let returnedResult = "Continued in Claude."

    /// Records that the person took the proposal into a session they direct. The agent reads
    /// the stamp as their answer: this one was worth working through together. The app's own
    /// record of a handoff is `HandoffLedger`, since the agent can rewrite this file.
    static func recordHandoff(
        id: String,
        in directory: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws {
        var fields = try readFields(id: id, in: directory)
        fields["handedOff"] = now.formatted(.iso8601)
        fields["handedOffLocal"] = ProVisorClock.localStamp(now, timeZone: timeZone)
        try write(fields, id: id, in: directory)
    }

    /// Takes the handoff stamp off a proposal whose session never opened.
    static func removeHandoff(id: String, in directory: URL) throws {
        var fields = try readFields(id: id, in: directory)
        fields["handedOff"] = nil
        fields["handedOffLocal"] = nil
        try write(fields, id: id, in: directory)
    }

    /// What recording a return did.
    enum ReturnSettlement: Equatable {
        /// The proposal was open and is now done.
        case settled
        /// The return was stamped on a proposal that is decided, or is being carried out.
        case stamped
    }

    /// Records that the session a proposal was handed to left its findings; the caller
    /// vouches that it was handed off (`HandoffLedger`). The status is decided by the file on
    /// disk: a proposal still awaiting a decision becomes done and cleared, since the person
    /// was there for the work and has nothing new to be told, and one already decided keeps
    /// its outcome and gains the stamp.
    ///
    /// With `settlesOpen` false an open proposal is stamped and left open: a run already
    /// carrying it out records the outcome itself.
    static func recordReturn(
        id: String,
        in directory: URL,
        settlesOpen: Bool = true,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> ReturnSettlement {
        var fields = try readFields(id: id, in: directory)
        fields["returned"] = now.formatted(.iso8601)
        let status: Proposal.Status? = switch fields["status"] {
        case nil: .proposed
        case let name as String: Proposal.Status(rawValue: name)
        default: nil
        }
        let isOpen = settlesOpen && (status == .proposed || status == .failed)
        if isOpen {
            stamp(.done, into: &fields, now: now, timeZone: timeZone)
            fields["result"] = returnedResult
            fields["cleared"] = true
        }
        try write(fields, id: id, in: directory)
        return isOpen ? .settled : .stamped
    }

    private static func url(id: String, in directory: URL) throws -> URL {
        guard Proposal.isValidID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        return directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private static func readFields(id: String, in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url(id: id, in: directory))
        guard data.count <= Proposal.maximumFileBytes,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        return fields
    }

    private static func stamp(
        _ status: Proposal.Status,
        into fields: inout [String: Any],
        now: Date,
        timeZone: TimeZone
    ) {
        fields["status"] = status.rawValue
        fields["decided"] = now.formatted(.iso8601)
        // The weekday and local hour, spelled out. Whether the user approves something on
        // Tuesdays, or first thing in the morning, is a pattern the agent is asked to find,
        // and working a weekday out from a UTC timestamp is where a model slips.
        fields["decidedLocal"] = ProVisorClock.localStamp(now, timeZone: timeZone)
    }

    private static func write(_ fields: [String: Any], id: String, in directory: URL) throws {
        let updated = try JSONSerialization.data(withJSONObject: fields, options: writingOptions)
        // A file over the limit would be skipped on the next load.
        guard updated.count <= Proposal.maximumFileBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try updated.write(to: url(id: id, in: directory), options: .atomic)
    }
}
