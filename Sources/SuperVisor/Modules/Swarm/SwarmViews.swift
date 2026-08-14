import AppKit
import SwiftUI

/// The Claude starburst mark (transparent background), shipped as a vector in the bundle's
/// resources and resolved once per launch.
@MainActor
private let claudeSymbol: NSImage? = {
    guard let url = Bundle.main.url(forResource: "ClaudeSymbol", withExtension: "svg") else {
        return nil
    }
    return NSImage(contentsOf: url)
}()

/// Leading identity marker for swarm surfaces: the Claude mark, so an agent-session row reads
/// as Claude at a glance. Falls back to the module glyph if the bundled asset is missing.
@MainActor
private struct ClaudeSessionIcon: View {
    let size: CGFloat

    var body: some View {
        if let claudeSymbol {
            Image(nsImage: claudeSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(NotchTheme.brandGradient)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
struct SwarmExpandedView: View {
    @ObservedObject var center: AgentFleetCenter
    @ObservedObject var settings: SettingsStore
    let terminalTeleport: TerminalTeleport

    /// Whether the folded group of long-idle sessions is open. Resets with the sheet, which is
    /// built only while it is expanded or hovered, so the queue opens folded every time.
    @State private var showsIdle = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let split = SwarmQueuePresentation.split(center.queue, now: context.date)

            VStack(alignment: .leading, spacing: 9) {
                if !split.current.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(split.current) { entry in
                            row(entry, now: context.date)
                        }
                    }
                }

                if !split.idle.isEmpty {
                    idleGroup(split.idle, now: context.date)
                }

                if center.workingCount > 0 {
                    Text("\(center.workingCount) working")
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sessions that stopped long enough ago to be history rather than triage, folded behind a
    /// count. They keep their full rows once opened: a session is still dismissible and still
    /// worth jumping to, it just no longer earns sheet height unprompted.
    private func idleGroup(_ entries: [AttentionEntry], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsIdle.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("\(entries.count) idle")
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                    Image(systemName: showsIdle ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsIdle {
                ForEach(entries) { entry in
                    row(entry, now: now)
                }
            }
        }
    }

    private func row(_ entry: AttentionEntry, now: Date) -> some View {
        SwarmAttentionRow(
            entry: entry,
            now: now,
            showsMessages: settings.swarmShowsMessages,
            terminalTeleport: terminalTeleport,
            onDismiss: {
                center.dismiss(entry.sessionPID)
            }
        )
    }
}

/// How the sheet arranges the attention queue.
enum SwarmQueuePresentation {
    /// How long a session that merely stopped — its turn over, nothing blocking it — keeps a row
    /// of its own. Inside that window its closing summary is still what the user stepped away
    /// from; past it the row is history, competing for sheet height with sessions that are
    /// genuinely stuck.
    static let idleFoldAge: TimeInterval = 3600

    struct Split: Equatable {
        /// Sessions worth a row unprompted: anything blocked, plus recently-stopped sessions.
        let current: [AttentionEntry]
        /// Long-stopped sessions, folded behind a count.
        let idle: [AttentionEntry]
    }

    /// Sessions that cannot proceed lead: a prompt frozen on screen costs more than a finished
    /// turn sitting at an idle prompt. Within each group the most recent leads, so the session
    /// the user last stepped away from stays at hand, and the session PID settles a remaining tie
    /// — `sorted(by:)` gives no stability guarantee, and rows that swapped places between the
    /// 30-second reticks would be unreadable.
    ///
    /// A blocked session never folds however long it has waited: it is stopped until the user
    /// deals with it, and time only makes that more true.
    /// The session a jump goes to: the one the banner is announcing, else the queue's first —
    /// its most pressing, the queue being ordered blocked-first then most-recent. Entries with no
    /// validated tty are skipped, since nothing can focus a session whose terminal was never
    /// identified.
    static func pressingSession(
        announced: AttentionEntry?,
        queue: [AttentionEntry]
    ) -> AttentionEntry? {
        if let announced, announced.tty != nil { return announced }
        return queue.first { $0.tty != nil }
    }

    static func split(_ queue: [AttentionEntry], now: Date) -> Split {
        let ordered = queue.sorted { first, second in
            if first.reason.isBlocking != second.reason.isBlocking {
                return first.reason.isBlocking
            }
            if first.since != second.since { return first.since > second.since }
            return first.sessionPID < second.sessionPID
        }
        let folded = ordered.partitioned { entry in
            !entry.reason.isBlocking && now.timeIntervalSince(entry.since) >= idleFoldAge
        }
        return Split(current: folded.unmatched, idle: folded.matched)
    }
}

private extension Array {
    /// Split into the elements satisfying `predicate` and those that do not, each keeping the
    /// receiver's order.
    func partitioned(by predicate: (Element) -> Bool) -> (matched: [Element], unmatched: [Element]) {
        var matched: [Element] = []
        var unmatched: [Element] = []
        for element in self {
            if predicate(element) {
                matched.append(element)
            } else {
                unmatched.append(element)
            }
        }
        return (matched, unmatched)
    }
}

/// The banner a session raises for a few seconds as it enters the attention queue: who it is,
/// why it stopped, and a way straight into its terminal.
@MainActor
struct SwarmPeekBannerView: View {
    @ObservedObject var module: SwarmModule
    @ObservedObject var settings: SettingsStore

    var body: some View {
        if let entry = module.announcedEntry {
            let parts = SwarmReason.parts(
                of: entry.reason,
                showsMessages: settings.swarmShowsMessages
            )

            HStack(spacing: 10) {
                SwarmAttentionMarker(entry: entry, size: NotchTheme.compactContentHeight)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NotchTheme.primaryForeground)
                        .lineLimit(1)

                    SwarmReasonLine(parts: parts)
                }
                // A message runs to several hundred characters, and the banner's measured width
                // is what the surface grows to; the cap keeps one long message from stretching
                // the pill across the screen.
                .frame(maxWidth: 280, alignment: .leading)

                // The pill can be wider than the banner needs (compact content on the flanks, a
                // longer row above), so the action pins to the trailing content edge.
                Spacer(minLength: 12)

                if let tty = entry.tty {
                    SwarmIconButton(
                        systemName: "apple.terminal",
                        tooltip: "Open in iTerm2",
                        showsHoverLabel: false
                    ) {
                        module.jump(toTTY: tty)
                    }
                }
            }
        }
    }
}

@MainActor
private struct SwarmAttentionRow: View {
    let entry: AttentionEntry
    let now: Date
    let showsMessages: Bool
    let terminalTeleport: TerminalTeleport
    let onDismiss: () -> Void

    var body: some View {
        let parts = SwarmReason.parts(of: entry.reason, showsMessages: showsMessages)

        HStack(spacing: NotchTheme.rowMarkerGap) {
            SwarmAttentionMarker(entry: entry, size: NotchTheme.rowMarkerWidth)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NotchTheme.primaryForeground)
                        .lineLimit(1)

                    Text(Self.lastPathComponent(entry.cwd))
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    SwarmReasonLine(parts: parts)

                    Text(Self.age(since: entry.since, now: now))
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let tty = entry.tty {
                SwarmIconButton(
                    systemName: "apple.terminal",
                    tooltip: "Open in iTerm2",
                    showsHoverLabel: false
                ) {
                    terminalTeleport.teleport(toTTY: tty)
                }
            }

            SwarmIconButton(systemName: "xmark", tooltip: "Dismiss", action: onDismiss)
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }

    private static func age(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// The reason line: a short label naming the state, and the detail that earns the row its place.
/// The detail truncates to one line, and hovering reveals it whole — a final message can be a
/// paragraph, and the sheet has room for a clause of it.
@MainActor
private struct SwarmReasonLine: View {
    let parts: SwarmReason.Parts

    var body: some View {
        let line = HStack(spacing: 4) {
            Text(parts.label)
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .lineLimit(1)
                .layoutPriority(1)

            if let detail = parts.detail {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.separator)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }

        if let detail = parts.detail, parts.isTruncatable {
            line.notchTooltip(detail).help(detail)
        } else {
            line
        }
    }
}

/// The Claude icon marks an agent session at a glance — the calendar rows in the adjacent section
/// lead with plain accent dots. The badge dot in its corner carries the state.
@MainActor
private struct SwarmAttentionMarker: View {
    let entry: AttentionEntry
    let size: CGFloat

    var body: some View {
        ClaudeSessionIcon(size: size)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusStyle)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(NotchTheme.notchBlack, lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
    }

    private var statusStyle: AnyShapeStyle {
        switch entry.reason {
        case .failed:
            AnyShapeStyle(Color.red)
        case .waiting:
            AnyShapeStyle(Color.orange)
        case .asked, .needsInput:
            AnyShapeStyle(NotchTheme.brandGradient)
        case .finished:
            AnyShapeStyle(Color.green)
        }
    }
}

@MainActor
private struct SwarmIconButton: View {
    let systemName: String
    let tooltip: String
    /// The jump button's glyph names its destination, so it carries no hover label; `tooltip`
    /// still voices it for accessibility.
    var showsHoverLabel = true
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: NotchTheme.rowActionSize, height: NotchTheme.rowActionSize)
                .foregroundStyle(NotchTheme.primaryForeground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)

        if showsHoverLabel {
            button.notchTooltip(tooltip)
        } else {
            button
        }
    }
}

/// Turns a reason into the two strings a row shows.
enum SwarmReason {
    struct Parts: Equatable {
        let label: String
        let detail: String?
        /// Whether `detail` is model-generated text that can run past the row's width, and so
        /// earns a hover tooltip carrying it whole.
        let isTruncatable: Bool
    }

    /// `showsMessages` gates only session content — a question, a closing summary, an error's
    /// detail text. Labels, tool names, and error codes are fixed vocabulary and always show.
    static func parts(of reason: AttentionReason, showsMessages: Bool) -> Parts {
        switch reason {
        case let .waiting(detail):
            if let tool = approvalTool(in: detail) {
                return Parts(label: "Approve", detail: tool, isTruncatable: false)
            }
            return Parts(label: sentenceCased(detail), detail: nil, isTruncatable: false)

        case let .failed(error, details):
            return Parts(
                label: sentenceCased(error.replacingOccurrences(of: "_", with: " ")),
                detail: showsMessages ? details : nil,
                isTruncatable: true
            )

        case let .asked(question):
            return Parts(
                label: "Asked",
                detail: showsMessages ? question : nil,
                isTruncatable: true
            )

        case let .finished(turnDuration, summary):
            let label = turnDuration.map { "Done \(turnLength($0))" } ?? "Done"
            return Parts(
                label: label,
                detail: showsMessages ? summary : nil,
                isTruncatable: true
            )

        case .needsInput:
            return Parts(label: "Needs input", detail: nil, isTruncatable: false)
        }
    }

    private static let approvalPrefix = "approve "

    private static func approvalTool(in detail: String) -> String? {
        guard detail.hasPrefix(approvalPrefix) else { return nil }
        let tool = detail.dropFirst(approvalPrefix.count)
        return tool.isEmpty ? nil : String(tool)
    }

    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func turnLength(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
