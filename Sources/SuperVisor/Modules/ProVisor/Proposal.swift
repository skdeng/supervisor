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
    /// Set when the user clears a finished proposal's row. The status stays `done`, so the
    /// agent still reads the proposal as one that was wanted.
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
            choice: parsedChoice(fields, optionCount: options.count)
        )
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

    private static func date(_ value: Any?) -> Date? {
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
    /// carried out and not yet cleared. Something done under a standing approval is shown so
    /// the user can see what happened, and then leaves by itself after a day — rows that had to
    /// be cleared by hand would turn "stop asking me" into a different chore. Within each group
    /// the newest leads, and the id settles a tie so a reload never reshuffles the rows.
    static func visible(_ proposals: [Proposal], now: Date) -> [Proposal] {
        proposals
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
        guard Proposal.isValidID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = directory.appendingPathComponent("\(id).json", isDirectory: false)
        let data = try Data(contentsOf: url)
        guard data.count <= Proposal.maximumFileBytes,
              var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }

        if let status {
            fields["status"] = status.rawValue
            fields["decided"] = now.formatted(.iso8601)
            // The weekday and local hour, spelled out. Whether the user approves something on
            // Tuesdays, or first thing in the morning, is a pattern the agent is asked to find,
            // and working a weekday out from a UTC timestamp is where a model slips.
            fields["decidedLocal"] = ProVisorClock.localStamp(now, timeZone: timeZone)
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

        let updated = try JSONSerialization.data(withJSONObject: fields, options: writingOptions)
        // A file over the limit would be skipped on the next load.
        guard updated.count <= Proposal.maximumFileBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try updated.write(to: url, options: .atomic)
    }
}
