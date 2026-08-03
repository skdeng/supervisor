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
    let terminalTeleport: TerminalTeleport

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !center.queue.isEmpty {
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(center.queue) { entry in
                            SwarmAttentionRow(
                                entry: entry,
                                now: context.date,
                                terminalTeleport: terminalTeleport,
                                onDismiss: {
                                    center.dismiss(entry.sessionPID)
                                }
                            )
                        }
                    }
                }
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

/// The banner a session raises for a few seconds as it enters the attention queue: who it is,
/// why it stopped, and a way straight into its terminal.
@MainActor
struct SwarmPeekBannerView: View {
    @ObservedObject var module: SwarmModule

    var body: some View {
        if let entry = module.announcedEntry {
            HStack(spacing: 10) {
                SwarmAttentionMarker(entry: entry, size: NotchTheme.compactContentHeight)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NotchTheme.primaryForeground)
                        .lineLimit(1)

                    Text(reasonText(entry.reason))
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }
                // A needs-input message runs to 200 characters, and the banner's measured width
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
    let terminalTeleport: TerminalTeleport
    let onDismiss: () -> Void

    var body: some View {
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
                    Text(reasonText(entry.reason))
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)

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

/// The Claude icon marks an agent session at a glance — the calendar rows in the adjacent section
/// lead with plain accent dots. The badge dot in its corner carries the state: brand gradient
/// while the session waits for input, green once the turn finished.
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
        case .needsInput:
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
                .frame(width: 24, height: 24)
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

private func reasonText(_ reason: AttentionReason) -> String {
    switch reason {
    case let .finished(duration):
        return "Finished after \(turnDuration(duration))"
    case let .needsInput(message):
        guard let message else { return "Needs input" }
        return "Needs input · \(message)"
    }
}

private func turnDuration(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}
