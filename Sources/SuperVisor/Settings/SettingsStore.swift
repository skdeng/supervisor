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
        static let trueSpectrum = "media.trueSpectrum"
        static let beatAura = "media.beatAura"
        static let callAutoPauseMusic = "calls.autoPauseMusic"
        static let flowWorkInterval = "flow.workInterval"
        static let flowBreakLength = "flow.breakLength"
        static let flowDeferDuringMeetings = "flow.deferDuringMeetings"
        static let swarmShowMessages = "swarm.showMessages"
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

    /// MusicVisor: render the compact equalizer from the real system audio via a CoreAudio
    /// process tap (macOS shows a recording indicator while it runs and asks for System Audio
    /// Recording permission once). Off = the synthesized bounce, no tap, no indicator.
    @Published public var trueSpectrumEnabled: Bool {
        didSet { defaults.set(trueSpectrumEnabled, forKey: Key.trueSpectrum) }
    }

    /// MusicVisor: pulse a glow around the notch, tinted with the artwork color, following the
    /// music's bass. Only active while the spectrum tap is capturing.
    @Published public var beatAuraEnabled: Bool {
        didSet { defaults.set(beatAuraEnabled, forKey: Key.beatAura) }
    }

    /// CallSense: pause active media during a detected call and resume only while the automatic
    /// pause still owns the playback state.
    @Published public var callAutoPausesMusic: Bool {
        didSet { defaults.set(callAutoPausesMusic, forKey: Key.callAutoPauseMusic) }
    }

    /// FlowVisor: minutes of heads-down work before break nudges become eligible.
    @Published public var flowWorkIntervalMinutes: Int {
        didSet { defaults.set(flowWorkIntervalMinutes, forKey: Key.flowWorkInterval) }
    }

    /// FlowVisor: duration in minutes of an explicitly started break.
    @Published public var flowBreakLengthMinutes: Int {
        didSet { defaults.set(flowBreakLengthMinutes, forKey: Key.flowBreakLength) }
    }

    /// FlowVisor: delays a break nudge until all currently overlapping calendar events end.
    @Published public var flowDeferDuringMeetings: Bool {
        didSet { defaults.set(flowDeferDuringMeetings, forKey: Key.flowDeferDuringMeetings) }
    }

    /// SwarmVisor: show what a session actually said — the question it asked, its closing
    /// summary, an error's detail text. Off by default: the sheet floats above every other
    /// window, so session content would otherwise be on screen during a screen share.
    @Published public var swarmShowsMessages: Bool {
        didSet { defaults.set(swarmShowsMessages, forKey: Key.swarmShowMessages) }
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
        self.trueSpectrumEnabled = (defaults.object(forKey: Key.trueSpectrum) as? Bool) ?? true
        self.beatAuraEnabled = (defaults.object(forKey: Key.beatAura) as? Bool) ?? true
        self.callAutoPausesMusic =
            (defaults.object(forKey: Key.callAutoPauseMusic) as? Bool) ?? false
        let storedWorkInterval = defaults.integer(forKey: Key.flowWorkInterval)
        self.flowWorkIntervalMinutes = [45, 60, 90].contains(storedWorkInterval)
            ? storedWorkInterval
            : 60
        let storedBreakLength = defaults.integer(forKey: Key.flowBreakLength)
        self.flowBreakLengthMinutes = [3, 5, 10].contains(storedBreakLength)
            ? storedBreakLength
            : 5
        self.flowDeferDuringMeetings =
            (defaults.object(forKey: Key.flowDeferDuringMeetings) as? Bool) ?? true
        self.swarmShowsMessages =
            (defaults.object(forKey: Key.swarmShowMessages) as? Bool) ?? false

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
