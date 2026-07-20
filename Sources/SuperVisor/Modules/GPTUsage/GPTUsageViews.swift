import SwiftUI

/// The GPT usage ticker. Observation stays in this wrapper while all visual choices are shared
/// with Claude Usage through `UsageTickerRowView`.
struct GPTUsageRowView: View {
    @ObservedObject var monitor: CodexQuotaMonitor

    var body: some View {
        if let quota = monitor.quota, !quota.windows.isEmpty {
            UsageTickerRowView(productName: "GPT", windows: quota.windows)
        }
    }
}
