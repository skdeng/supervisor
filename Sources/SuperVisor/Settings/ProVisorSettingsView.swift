import AppKit
import SwiftUI

/// ProVisor's options: how often it looks, a way to make it look now, how the last pass went,
/// and a door into the folder holding its brief and its tool access.
///
/// The last pass's summary is the agent's own account of where it looked and what got in its
/// way, so this is also where a misconfiguration shows up — a connector it expected and did
/// not have, a Claude Code too old for the flags that confine it.
struct ProVisorSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: ProVisorCenter

    var body: some View {
        Picker("Look for ideas", selection: $settings.provisorScoutHours) {
            Text("Only when asked").tag(0)
            Text("Every 3 hours").tag(3)
            Text("Every 6 hours").tag(6)
            Text("Once a day").tag(24)
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusTint)

                Spacer()

                Button("Open Folder", action: openFolder)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))

                Button("Look Now") { center.scoutNow() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .disabled(!center.isActive || center.isScouting)
            }

            if let report = center.lastScout {
                Text(report.text)
                    .font(.caption)
                    .foregroundStyle(report.failed ? Color.red : Color.secondary)
            }

            Text("Runs Claude Code in the background on this Mac to read your mail and calendar through the connectors you added in Claude, and lists what it thinks you would want done. While looking it can only read. Nothing changes until you approve a proposal, and by default an approved action can organize mail and write drafts but cannot send. Its brief (CHARTER.md) and the connector tools it may use (access.json) are in its folder and are yours to edit. Uses your Claude plan, and needs a recent Claude Code signed in with your Claude account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if center.isScouting { return "Looking now…" }
        if center.lastScout?.failed == true { return "Last pass failed" }
        guard let last = center.lastScoutDate else { return "Has not looked yet" }
        return "Last looked \(last.formatted(.relative(presentation: .named)))"
    }

    private var statusSymbol: String {
        if center.isScouting { return "sparkles" }
        if center.lastScout?.failed == true { return "exclamationmark.triangle.fill" }
        return center.lastScoutDate == nil ? "circle.dashed" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if center.isScouting { return .secondary }
        if center.lastScout?.failed == true { return .orange }
        return center.lastScoutDate == nil ? .secondary : .green
    }

    private func openFolder() {
        try? ProVisorHome.prepare()
        NSWorkspace.shared.open(ProVisorHome.rootURL)
    }
}
