import SwiftUI

/// Installs and removes the Claude Code session hooks SwarmVisor reads.
///
/// SwarmVisor lists sessions and tracks busy/idle/waiting from the session registry with no
/// hooks at all. Hooks add what the registry omits: the terminal to jump to, what a finished
/// turn said, and why a turn failed.
struct AgentHookSettingsView: View {
    @State private var state: AgentHookInstallState = .absent
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusTint)

                Spacer()

                if state.isWired {
                    Button("Remove", action: uninstall)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                }

                Button(state == .installed ? "Reinstall" : primaryActionTitle, action: install)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
            }

            Text("Writes a hook script to ~/.claude/hooks and adds six entries to Claude Code's settings.json. Your existing hooks are left alone, and the original file is copied to settings.json.pre-supervisor.bak before the first change.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { refresh() }
    }

    private var statusText: String {
        switch state {
        case .absent: "Session hooks not installed"
        case .outdated: "Session hooks out of date"
        case .installed: "Session hooks installed"
        }
    }

    private var statusSymbol: String {
        switch state {
        case .absent: "circle.dashed"
        case .outdated: "exclamationmark.triangle.fill"
        case .installed: "checkmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch state {
        case .absent: .secondary
        case .outdated: .orange
        case .installed: .green
        }
    }

    private var primaryActionTitle: String {
        state == .outdated ? "Update" : "Install"
    }

    private func install() {
        run { try AgentHookInstaller.install() }
    }

    private func uninstall() {
        run { try AgentHookInstaller.uninstall() }
    }

    private func run(_ operation: () throws -> Void) {
        do {
            try operation()
            failure = nil
        } catch {
            failure = error.localizedDescription
            AppLog.error(.swarm, "hook install failed \(error.localizedDescription)")
        }
        refresh()
    }

    private func refresh() {
        state = AgentHookInstaller.currentState()
    }
}
