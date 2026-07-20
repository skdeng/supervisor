import AppKit
import SwiftUI

/// Compact trailing contribution: a checklist glyph with the count of due/overdue tasks, tinted
/// red when any are overdue.
struct RemindersCompactView: View {
    @ObservedObject var service: RemindersService

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let count = service.reminders.count
            let overdue = service.reminders.contains { $0.isOverdue(asOf: context.date) }
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(overdue ? .red : NotchTheme.primaryForeground)
            .fixedSize()
        }
    }
}

/// Expanded section: a checklist of due/overdue reminders, each with a tap-to-complete checkbox,
/// its list color, a live due/overdue line, and a high-priority marker.
struct RemindersChecklistView: View {
    @ObservedObject var service: RemindersService
    let onComplete: (String) -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array(service.reminders.prefix(8))) { item in
                row(item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
        .animation(.snappy(duration: 0.2), value: service.reminders)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 14, weight: .semibold))
            Text("Tasks")
                .font(.headline)
            Spacer()
            Text("\(service.reminders.count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    private func row(_ item: ReminderItem) -> some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let overdue = item.isOverdue(asOf: context.date)
            HStack(spacing: 10) {
                Button {
                    onComplete(item.id)
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(item.accent)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Complete")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(NotchTheme.primaryForeground)
                    Text(subtitle(item, overdue: overdue))
                        .font(.caption)
                        .foregroundStyle(overdue ? Color.red : NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if item.isHighPriority {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func subtitle(_ item: ReminderItem, overdue: Bool) -> String {
        if overdue {
            return item.hasTime ? "Overdue · \(Self.timeFormatter.string(from: item.due))" : "Overdue"
        }
        if item.hasTime {
            return Self.timeFormatter.string(from: item.due)
        }
        return "Today"
    }
}

/// Shown when Reminders access is denied: a brief prompt with a shortcut to System Settings.
struct RemindersAccessPromptView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                Text("Tasks")
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(NotchTheme.primaryForeground)

            Text("Allow Reminders access to see your due tasks here.")
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)

            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(NotchTheme.brandGradient)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }
}
