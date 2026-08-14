import AppKit
import SwiftUI

/// The settings surface: one section per module — its enable toggle followed by its own
/// options — plus presentation and debug. Backed by `SettingsStore`; changes persist and the
/// engine reacts live.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// (id, displayName) pairs for every registered module, sorted by name. Captured at
    /// window-open time from the registry so toggles render even when modules are disabled.
    let modules: [ModuleInfo]

    var body: some View {
        Form {
            Section("Presentation") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hover sensitivity")
                    Slider(value: $settings.hoverSensitivity, in: 0...1)
                    HStack {
                        Text("Relaxed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Eager").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(modules) { module in
                Section {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { settings.isEnabled(module.id) },
                            set: { settings.setEnabled($0, for: module.id) }
                        )
                    )
                    moduleOptions(for: module.id)
                        .disabled(!settings.isEnabled(module.id))
                } header: {
                    Label(module.displayName, systemImage: Self.moduleSymbol(for: module.id))
                }
            }

            Section("Debug") {
                Toggle("Tint notch & sheet bright red", isOn: $settings.debugTintEnabled)
                Button("Open Log Folder") {
                    try? FileManager.default.createDirectory(
                        at: FileLogMirror.directoryURL,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(FileLogMirror.directoryURL)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                Text("Colors the rendered surface red so you can see its exact bounds against the hardware notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 680)
        // Tooltips render through a per-window host; this window is its own hierarchy, so it
        // carries one of its own.
        .notchTooltipHost()
    }

    /// The glyph each module's section header carries, matching the symbol the module shows
    /// on the notch surface itself where it has one.
    private static func moduleSymbol(for moduleID: String) -> String {
        switch moduleID {
        case "media": "waveform"
        case "calendar": "calendar"
        case "reminders": "checklist"
        case "fileshelf": "tray.full.fill"
        case "flow": "brain.head.profile"
        case "swarm": "person.2.wave.2.fill"
        case "battery": "battery.100"
        case "aiUsage": "gauge.with.needle"
        default: "puzzlepiece.extension"
        }
    }

    /// Module-specific options rendered under that module's enable toggle. Modules without
    /// extra options contribute nothing beyond the toggle.
    @ViewBuilder
    private func moduleOptions(for moduleID: String) -> some View {
        switch moduleID {
        case "media":
            Toggle("Live audio spectrum", isOn: $settings.trueSpectrumEnabled)
            Text("Draws the equalizer from the actual system audio. macOS asks once for System Audio Recording permission and shows a recording indicator in the menu bar while music plays. Off: an animated equalizer with no audio access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Beat aura", isOn: $settings.beatAuraEnabled)
            Text("Pulses a glow around the notch in the artwork's color, following the music's bass. Requires the live audio spectrum.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                "Pause music when a call starts",
                isOn: $settings.callAutoPausesMusic
            )
            .notchTooltip("Pause music when a call starts")
            .help("Pause music when a call starts")
            Text("Detects a call from system-wide camera or microphone use. Music resumes when the call ends; a manual pause is never overridden.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case "flow":
            Picker("Work interval", selection: $settings.flowWorkIntervalMinutes) {
                Text("45 min").tag(45)
                Text("60 min").tag(60)
                Text("90 min").tag(90)
            }

            Picker("Break length", selection: $settings.flowBreakLengthMinutes) {
                Text("3 min").tag(3)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
            }

            Toggle("Defer nudges during meetings", isOn: $settings.flowDeferDuringMeetings)
            Text("Uses the existing Calendar permission and reads only event start and end times.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case "swarm":
            AgentHookSettingsView()

            Toggle("Jump to the waiting session with ⌘⇧⎋", isOn: $settings.swarmJumpHotKeyEnabled)
            Text("Focuses the iTerm2 tab of the session that most needs attention — the one the banner is announcing, otherwise the first blocked session in the queue. The shortcut is claimed only while a session is reachable; the rest of the time ⌘⇧⎋ goes to the app you are using.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show what a session said", isOn: $settings.swarmShowsMessages)
            Text("Adds the question a session asked, its closing summary, or an error's detail text to each row; hover a row for the full text. Off keeps rows to a state and a tool name, so no session content sits on screen during a screen share.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// Lightweight descriptor for a module shown in settings.
struct ModuleInfo: Identifiable {
    let id: String
    let displayName: String
}
