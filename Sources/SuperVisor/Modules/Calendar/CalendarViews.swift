import AppKit
import SwiftUI

/// Compact leading contribution: a small chip with a meeting glyph and a live countdown to the
/// next meeting ("12m", "1m", "Now"). Drives its own minute-by-minute update via a timeline so
/// the engine doesn't need to re-publish; turns an attention tint as the meeting nears.
struct CalendarCompactView: View {
    let event: CalendarEvent

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 15)) { context in
            chip(now: context.date)
        }
    }

    private func chip(now: Date) -> some View {
        let ongoing = event.isOngoing(asOf: now)
        let seconds = event.secondsUntilStart(asOf: now)
        let soon = seconds <= 5 * 60
        let tint: Color = ongoing ? .green : (soon ? .orange : event.accent)

        return HStack(spacing: 5) {
            Image(systemName: event.hasJoin ? "video.fill" : "calendar")
                .font(.system(size: 10, weight: .semibold))
            Text(Self.countdownLabel(ongoing: ongoing, seconds: seconds))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
    }

    static func countdownLabel(ongoing: Bool, seconds: TimeInterval) -> String {
        if ongoing || seconds <= 0 { return "Now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
    }
}

/// Expanded section: a small agenda of upcoming meetings, each with its calendar color, a live
/// "starts in / now" line, and a one-tap Join button when a meeting link was detected.
struct CalendarAgendaView: View {
    let events: [CalendarEvent]
    @ObservedObject var dismissals: MeetingDismissalStore
    let onJoin: (URL) -> Void
    let onDismiss: (CalendarEvent) -> Void
    let onRestore: (String) -> Void

    @State private var showsDismissed = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(events) { event in
                eventRow(event)
            }
            if !dismissals.dismissed.isEmpty {
                dismissedFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let ongoing = event.isOngoing(asOf: context.date)
            HStack(spacing: NotchTheme.rowMarkerGap) {
                Circle()
                    .fill(event.accent)
                    .frame(width: 8, height: 8)
                    .frame(width: NotchTheme.rowMarkerWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(NotchTheme.primaryForeground)
                    Text(subtitle(event, ongoing: ongoing, now: context.date))
                        .font(.caption)
                        .foregroundStyle(ongoing ? Color.green : NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let url = event.joinURL {
                    joinButton(url: url)
                }
                dismissButton(event)
            }
        }
    }

    private func joinButton(url: URL) -> some View {
        Button {
            onJoin(url)
        } label: {
            Image(systemName: "video.fill")
                .font(.system(size: 11, weight: .bold))
                .frame(width: NotchTheme.rowActionSize, height: NotchTheme.rowActionSize)
                .foregroundStyle(NotchTheme.primaryForeground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTooltip("Join")
        .help("Join")
    }

    private func dismissButton(_ event: CalendarEvent) -> some View {
        Button {
            onDismiss(event)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: NotchTheme.rowActionSize, height: NotchTheme.rowActionSize)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTooltip("Dismiss")
        .help("Dismiss")
    }

    private var dismissedFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsDismissed.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("\(dismissals.dismissed.count) dismissed")
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                    Image(systemName: showsDismissed ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDismissed {
                ForEach(dismissals.dismissed) { entry in
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .font(.caption)
                            .foregroundStyle(NotchTheme.secondaryForeground)
                            .strikethrough()
                            .lineLimit(1)
                        Text(Self.timeFormatter.string(from: entry.start))
                            .font(.caption2)
                            .foregroundStyle(NotchTheme.secondaryForeground)
                        Spacer(minLength: 6)
                        restoreButton(entry.id)
                    }
                }
            }
        }
    }

    private func restoreButton(_ id: String) -> some View {
        Button {
            onRestore(id)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .bold))
                .frame(width: NotchTheme.rowActionSize, height: NotchTheme.rowActionSize)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTooltip("Restore")
        .help("Restore")
    }

    private func subtitle(_ event: CalendarEvent, ongoing: Bool, now: Date) -> String {
        let startText = Self.timeFormatter.string(from: event.start)
        if ongoing {
            return "Now · until \(Self.timeFormatter.string(from: event.end))"
        }
        if now >= event.end {
            return "Ended"   // briefly present until the next reload rolls it off
        }
        let seconds = event.secondsUntilStart(asOf: now)
        if seconds < 3600 {
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            return "in \(minutes)m · \(startText)"
        }
        return startText
    }
}

/// Shown when calendar access is denied: a brief prompt with a shortcut to System Settings.
struct CalendarAccessPromptView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                Text("Calendar")
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(NotchTheme.primaryForeground)

            Text("Allow Calendar access to see your meetings here.")
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)

            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(NotchTheme.brandGradient)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
