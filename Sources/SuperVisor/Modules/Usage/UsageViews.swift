import SwiftUI

/// The Claude usage ticker row: `CLAUDE  5h 62% · 7d 34%  ↻ 4:30 PM`.
///
/// Half a row of monospaced text — no bars, no card chrome. Each percentage is colored by
/// headroom (quiet green under 70 %, amber to 90 %, red past it), so the color alone carries
/// the warning at a glance. The trailing reset time belongs to the first (soonest-cycling)
/// window, which is the 5-hour one whenever it is present.
struct UsageRowView: View {
    @ObservedObject var monitor: QuotaMonitor

    private static let ok = Color(red: 0.44, green: 0.75, blue: 0.51)
    private static let warn = Color(red: 0.88, green: 0.64, blue: 0.24)
    private static let crit = Color(red: 0.89, green: 0.38, blue: 0.30)

    var body: some View {
        if let quota = monitor.quota, !quota.windows.isEmpty {
            HStack(spacing: 10) {
                Text("CLAUDE")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1.1)
                    .foregroundStyle(NotchTheme.secondaryForeground)

                ticker(quota.windows)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                Spacer(minLength: 8)

                resetLabel(for: quota.windows[0].resetsAt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            .padding(.top, 2)
        }
    }

    /// `5h 62% · 7d 34%` with per-window headroom coloring, composed via Text interpolation
    /// into a single run so it lays out (and truncates) as one line.
    private func ticker(_ windows: [QuotaMonitor.Window]) -> Text {
        var text = Text(verbatim: "")
        for (index, window) in windows.enumerated() {
            let separator = index > 0
                ? Text(" · ").foregroundStyle(NotchTheme.secondaryForeground)
                : Text(verbatim: "")
            let label = Text("\(window.label) ")
                .foregroundStyle(NotchTheme.secondaryForeground)
            let percent = Text("\(Int(window.usedPercentage.rounded()))%")
                .foregroundStyle(color(forUsed: window.usedPercentage))
                .fontWeight(.semibold)
            text = Text("\(text)\(separator)\(label)\(percent)")
        }
        return text
    }

    /// Same-day resets show a bare time ("↻ 4:30 PM"); later ones add the weekday.
    private func resetLabel(for date: Date) -> Text {
        if Calendar.current.isDate(date, inSameDayAs: Date()) {
            return Text("↻ \(Text(date, format: .dateTime.hour().minute()))")
        }
        return Text("↻ \(Text(date, format: .dateTime.weekday(.abbreviated).hour().minute()))")
    }

    private func color(forUsed percentage: Double) -> Color {
        switch percentage {
        case ..<70: Self.ok
        case ..<90: Self.warn
        default: Self.crit
        }
    }
}
