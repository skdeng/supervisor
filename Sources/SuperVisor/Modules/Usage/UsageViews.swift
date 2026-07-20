import SwiftUI

/// The Claude usage ticker row: `CLAUDE  5h 62% · 7d 34%  ↻ 4:30 PM`.
///
/// The shared ticker owns all layout and styling so GPT Usage has exactly the same UX.
struct UsageRowView: View {
    @ObservedObject var monitor: QuotaMonitor

    var body: some View {
        if let quota = monitor.quota, !quota.windows.isEmpty {
            UsageTickerRowView(productName: "CLAUDE", windows: quota.windows)
        }
    }
}
