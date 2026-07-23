import SwiftUI

/// Both product ticker rows stacked tightly, so they read as one AI-usage block rather than
/// two separate sections. Each row gates on its own monitor's presence: a product whose CLI
/// has gone quiet drops out while the other stays.
struct AIUsageSectionView: View {
    @ObservedObject var claudeMonitor: QuotaMonitor
    @ObservedObject var codexMonitor: CodexQuotaMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if claudeMonitor.showsRow, let quota = claudeMonitor.quota, !quota.windows.isEmpty {
                UsageTickerRowView(productName: "CLAUDE", windows: quota.windows)
            }
            if codexMonitor.showsRow, let quota = codexMonitor.quota, !quota.windows.isEmpty {
                UsageTickerRowView(productName: "GPT", windows: quota.windows)
            }
        }
    }
}
