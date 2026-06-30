import SwiftUI

/// The settings surface: per-module enable toggles, the miniLake presentation toggle, and
/// hover sensitivity. Backed by `SettingsStore`; changes persist and the engine reacts live.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// (id, displayName) pairs for every registered module, sorted by name. Captured at
    /// window-open time from the registry so toggles render even when modules are disabled.
    let modules: [ModuleInfo]

    var body: some View {
        Form {
            Section("Presentation") {
                Toggle("miniLake (compact footprint)", isOn: $settings.miniLakeEnabled)

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

            Section("Modules") {
                if modules.isEmpty {
                    Text("No modules installed")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(modules) { module in
                        Toggle(
                            module.displayName,
                            isOn: Binding(
                                get: { settings.isEnabled(module.id) },
                                set: { settings.setEnabled($0, for: module.id) }
                            )
                        )
                    }
                }
            }

            Section("Debug") {
                Toggle("Tint notch & sheet bright red", isOn: $settings.debugTintEnabled)
                Text("Colors the rendered surface red so you can see its exact bounds against the hardware notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

/// Lightweight descriptor for a module shown in settings.
struct ModuleInfo: Identifiable {
    let id: String
    let displayName: String
}
