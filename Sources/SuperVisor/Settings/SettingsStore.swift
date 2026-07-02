import Foundation
import Combine

/// Persistent app settings backed by `UserDefaults`.
///
/// Owns the per-module enabled flags (default on) and hover sensitivity. Both
/// `ModuleRegistry`/engine (to filter modules) and the settings
/// UI consult and mutate this store. Changes publish so the settings window and engine
/// react live.
@MainActor
public final class SettingsStore: ObservableObject {
    /// Shared instance used across the app.
    public static let shared = SettingsStore()

    private let defaults: UserDefaults

    private enum Key {
        static let moduleEnabledPrefix = "module.enabled."
        static let hoverSensitivity = "hover.sensitivity"
        static let debugTint = "debug.tintRed"
        static let notchWidthAdjust = "notch.widthAdjust"
        static let notchOffsetX = "notch.offsetX"
    }

    /// Hover sensitivity in the range 0...1. Higher means a larger activation rect and a
    /// shorter dwell before expanding.
    @Published public var hoverSensitivity: Double {
        didSet { defaults.set(hoverSensitivity, forKey: Key.hoverSensitivity) }
    }

    /// Debug: tint the notch + sheet bright red so the rendered surface is easy to see
    /// against the hardware notch.
    @Published public var debugTintEnabled: Bool {
        didSet { defaults.set(debugTintEnabled, forKey: Key.debugTint) }
    }

    /// Calibration: points added to the OS-reported notch width (negative shrinks). macOS
    /// reports the menu-bar gap, which is wider than the visible cutout, so this lets the
    /// rendered notch be matched exactly to the hardware.
    @Published public var notchWidthAdjust: Double {
        didSet { defaults.set(notchWidthAdjust, forKey: Key.notchWidthAdjust) }
    }

    /// Calibration: points to shift the notch horizontally (positive = right).
    @Published public var notchOffsetX: Double {
        didSet { defaults.set(notchOffsetX, forKey: Key.notchOffsetX) }
    }

    /// Per-module enabled flags, keyed by `moduleID`. Absent ids default to enabled.
    @Published public private(set) var moduleEnabled: [String: Bool]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Key.hoverSensitivity) != nil {
            self.hoverSensitivity = defaults.double(forKey: Key.hoverSensitivity)
        } else {
            self.hoverSensitivity = 0.5
        }

        self.debugTintEnabled = defaults.bool(forKey: Key.debugTint)
        self.notchWidthAdjust = defaults.double(forKey: Key.notchWidthAdjust)
        self.notchOffsetX = defaults.double(forKey: Key.notchOffsetX)

        // Reconstruct the per-module map from any persisted keys.
        var map: [String: Bool] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(Key.moduleEnabledPrefix) else { continue }
            let id = String(key.dropFirst(Key.moduleEnabledPrefix.count))
            if let flag = value as? Bool {
                map[id] = flag
            }
        }
        self.moduleEnabled = map
    }

    /// Whether a module is enabled. Unknown ids default to `true`.
    public func isEnabled(_ moduleID: String) -> Bool {
        moduleEnabled[moduleID] ?? true
    }

    /// Set a module's enabled flag and persist it.
    public func setEnabled(_ enabled: Bool, for moduleID: String) {
        moduleEnabled[moduleID] = enabled
        defaults.set(enabled, forKey: Key.moduleEnabledPrefix + moduleID)
    }

    /// Ensure an entry exists for a module id so the settings UI can render a toggle even
    /// before the user has changed it. Defaults to enabled.
    public func registerModuleIfNeeded(_ moduleID: String) {
        if moduleEnabled[moduleID] == nil {
            moduleEnabled[moduleID] = true
        }
    }
}
