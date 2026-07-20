import SwiftUI

/// One quota window rendered by the shared Claude/GPT usage ticker.
struct UsageTickerWindow: Equatable {
    let label: String
    let usedPercentage: Double
    let resetsAt: Date
}

/// Shared usage ticker chrome: `<PRODUCT>  5h 62% · 7d 34%  ↻ 4:30 PM`.
///
/// Product-specific modules own observation and data acquisition; this view deliberately owns
/// every visual choice so Claude Usage and GPT Usage cannot drift apart.
struct UsageTickerRowView: View {
    let productName: String
    let windows: [UsageTickerWindow]

    private static let ok = Color(red: 0.44, green: 0.75, blue: 0.51)
    private static let warn = Color(red: 0.88, green: 0.64, blue: 0.24)
    private static let crit = Color(red: 0.89, green: 0.38, blue: 0.30)

    var body: some View {
        if !windows.isEmpty {
            HStack(spacing: 10) {
                Text(productName)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1.1)
                    .foregroundStyle(NotchTheme.secondaryForeground)

                ticker
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                Spacer(minLength: 8)

                resetLabel(for: windows[0].resetsAt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            .padding(.top, 2)
        }
    }

    /// Build one text run so the windows lay out and truncate as a unit while retaining their
    /// individual headroom colors.
    private var ticker: Text {
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

    /// Same-day resets show a bare time; later ones add the weekday.
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
