import Foundation

/// A rule the agent offers to make standing, attached to a proposal: a condition, what to do
/// when it holds, and the pattern in the user's past decisions that it was drawn from.
///
/// The agent works the condition out — this person, that weekday — from what the user approved
/// and what they dismissed. The basis is shown so the user can judge whether the line was drawn
/// in the right place; it is persuasion, not instruction, and never reaches a run.
struct StandingOffer: Equatable, Sendable {
    let condition: String
    let action: String
    let basis: String?

    static let basisLimit = 300

    /// Reads `{"when": …, "do": …, "because": …}`. The two parts that would govern later runs
    /// are never shortened to fit: an offer that cannot be shown whole is no offer.
    static func parse(_ value: Any?) -> StandingOffer? {
        guard let fields = value as? [String: Any],
              let condition = StandingRule.part(fields["when"]),
              let action = StandingRule.part(fields["do"])
        else { return nil }
        return StandingOffer(
            condition: condition,
            action: action,
            basis: Proposal.displayText(fields["because"], limit: basisLimit)
        )
    }
}

/// A rule the user agreed to in advance: when this holds, do that, without asking.
///
/// Both parts are the agent's wording, offered on a proposal and accepted by the user after
/// reading them in full. Whether a later action falls under the rule is the agent's judgment;
/// what such an action is *able* to do is not — see `StandingApprovals`.
struct StandingRule: Identifiable, Equatable, Sendable {
    let id: String
    /// When the rule applies: "Mail arrives from Maya Chen", "It is Tuesday".
    let condition: String
    /// What is done when it does.
    let action: String
    let since: Date
    /// When the user took it back. A revoked rule grants nothing. It is kept on file so the
    /// agent can be told never to offer it again.
    var revoked: Date?

    var isActive: Bool { revoked == nil }

    /// The most either part may run to.
    static let partLimit = 200

    /// One part of a rule, cleaned, or nil when it is missing or too long to show whole.
    static func part(_ value: Any?) -> String? {
        Proposal.displayText(value, limit: partLimit, truncates: false)
    }

    /// Anchored with `\A` and `\z`: ICU's `$` also matches before a trailing line terminator.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"\As-[0-9a-f]{8}\z"#, options: .regularExpression) != nil
    }
}

/// The user's standing approvals, kept in `standing.json` beside the brief — outside the
/// agent's working directory, so the agent can be told the rules but can never write one.
///
/// Letting an agent that reads mail from anyone act without review is safe only to the extent
/// the code bounds it, because everything the agent decides can be steered by what it read:
/// - A rule exists only because the user tapped **Always** on a proposal showing its condition
///   and action in full.
/// - A proposal's `under` is a claim. It counts only when it names a rule in force.
/// - A run under a rule gets its own, narrower tool list (`ProVisorAccess.auto`: by default
///   label, trash, and mark — nothing that sends or drafts, nothing that cannot be undone).
/// - At most `actionsPerPass` run per scouting pass; the rest wait for a tap.
/// - What was done is shown afterwards, with a way to revoke the rule it was done under.
///
/// So the worst a hostile message can achieve through a standing approval is some mail wrongly
/// labelled or moved to Trash, visibly, a handful at a time.
enum StandingApprovals {
    static let maximumRules = 100
    /// The most actions carried out under standing approvals per scouting pass.
    static let actionsPerPass = 5
    /// How long the row for something done under a rule stays in the sheet.
    static let automaticRowLifetime: TimeInterval = 24 * 3600

    /// The rule in force that a proposal may be carried out under, if there is one.
    static func rule(for proposal: Proposal, in rules: [StandingRule], now: Date) -> StandingRule? {
        guard proposal.status == .proposed, let under = proposal.under else { return nil }
        if let expires = proposal.expires, expires <= now { return nil }
        return rules.first { $0.id == under && $0.isActive }
    }

    /// A new rule from an accepted offer, or nil when a part is unusable or a rule in force
    /// already says the same thing.
    static func rule(
        adding offer: StandingOffer,
        to rules: [StandingRule],
        now: Date,
        id: String = newID()
    ) -> StandingRule? {
        guard rules.count < maximumRules,
              StandingRule.isValidID(id),
              !rules.contains(where: { $0.id == id }),
              let condition = StandingRule.part(offer.condition),
              let action = StandingRule.part(offer.action),
              !rules.contains(where: {
                  $0.isActive && $0.condition == condition && $0.action == action
              })
        else { return nil }
        return StandingRule(
            id: id,
            condition: condition,
            action: action,
            since: now,
            revoked: nil
        )
    }

    static func revoking(_ id: String, in rules: [StandingRule], now: Date) -> [StandingRule] {
        rules.map { rule in
            guard rule.id == id, rule.isActive else { return rule }
            var revoked = rule
            revoked.revoked = now
            return revoked
        }
    }

    static func newID() -> String {
        "s-" + String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
    }

    // MARK: - File

    /// Reads the rules. A malformed entry is skipped, which can only ever withhold a rule; a
    /// missing or unreadable file means no rules.
    static func load(from url: URL) -> [StandingRule] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [StandingRule] {
        guard data.count <= 256 << 10,
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let entries = fields["rules"] as? [Any]
        else { return [] }

        // Entry by entry: one stray value must not cost the user every rule they have, which a
        // whole-array cast would, and the next save would then write the loss to disk.
        var rules: [StandingRule] = []
        for entry in entries.prefix(maximumRules) {
            guard let entry = entry as? [String: Any],
                  let id = entry["id"] as? String,
                  StandingRule.isValidID(id),
                  !rules.contains(where: { $0.id == id }),
                  let condition = StandingRule.part(entry["when"]),
                  let action = StandingRule.part(entry["do"])
            else { continue }
            rules.append(StandingRule(
                id: id,
                condition: condition,
                action: action,
                since: date(entry["since"]) ?? .distantPast,
                revoked: date(entry["revoked"])
            ))
        }
        return rules
    }

    static func save(_ rules: [StandingRule], to url: URL) throws {
        let entries: [[String: Any]] = rules.map { rule in
            var entry: [String: Any] = [
                "id": rule.id,
                "when": rule.condition,
                "do": rule.action,
                "since": rule.since.formatted(.iso8601),
            ]
            if let revoked = rule.revoked {
                entry["revoked"] = revoked.formatted(.iso8601)
            }
            return entry
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["rules": entries],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.count <= 40 else { return nil }
        return try? Date(text, strategy: .iso8601)
    }
}
