import Foundation
import Combine

/// Persistent app settings backed by `UserDefaults`.
///
/// Owns the per-module enabled flags (default on, except opt-in modules) and hover
/// sensitivity. Both `ModuleRegistry`/engine (to filter modules) and the settings
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
        static let swarmShowMessages = "swarm.showMessages"
        static let swarmJumpHotKey = "swarm.jumpHotKey"
        static let provisorScoutHours = "provisor.scoutHours"
        static let provisorReadTexts = "provisor.readTexts"
        static let provisorOfferPasswords = "provisor.offerPasswords"
        static let provisorReadPhotoPlaces = "provisor.readPhotoPlaces"
        static let provisorSourceFolder = "provisor.sourceFolder"
        static let provisorReadDirectMessages = "provisor.readDirectMessages"
    }

    /// Modules that stay off until the user turns them on. ProVisor reads the user's mail and
    /// spends their Claude quota in the background, which is a choice to make, not a default.
    private static let optInModules: Set<String> = ["provisor"]

    /// The scouting cadences Settings offers, in hours; 0 means only when asked.
    public static let provisorScoutHourChoices = [0, 1, 3, 6, 24]

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

    /// SwarmVisor: show what a session actually said — the question it asked, its closing
    /// summary, an error's detail text. Off by default: the sheet floats above every other
    /// window, so session content would otherwise be on screen during a screen share.
    @Published public var swarmShowsMessages: Bool {
        didSet { defaults.set(swarmShowsMessages, forKey: Key.swarmShowMessages) }
    }

    /// SwarmVisor: whether ⌘⇧⎋ jumps to the session that most needs attention. The shortcut is
    /// claimed only while some session is actually reachable, so the rest of the time the
    /// keystroke belongs to whatever app is frontmost.
    @Published public var swarmJumpHotKeyEnabled: Bool {
        didSet { defaults.set(swarmJumpHotKeyEnabled, forKey: Key.swarmJumpHotKey) }
    }

    /// ProVisor: hours between automatic scouting passes; 0 runs one only when asked.
    @Published public var provisorScoutHours: Int {
        didSet { defaults.set(provisorScoutHours, forKey: Key.provisorScoutHours) }
    }

    /// ProVisor: whether the app reads the user's texts, for sign-in codes and as material for
    /// the agent. Off by default: it needs Full Disk Access and reaches private conversations.
    @Published public var provisorReadsTexts: Bool {
        didSet { defaults.set(provisorReadsTexts, forKey: Key.provisorReadTexts) }
    }

    /// ProVisor: whether the sign-in window records what the person types into a site's user
    /// name and password fields, so that after they sign in it can offer to keep the password
    /// in the Keychain.
    @Published public var provisorOffersPasswords: Bool {
        didSet { defaults.set(provisorOffersPasswords, forKey: Key.provisorOfferPasswords) }
    }

    /// ProVisor: whether the agent may read when and where the user's photos were taken. Off
    /// by default: it needs access to Photos and shows where the user has been.
    @Published public var provisorReadsPhotoPlaces: Bool {
        didSet { defaults.set(provisorReadsPhotoPlaces, forKey: Key.provisorReadPhotoPlaces) }
    }

    /// ProVisor: the path of SuperVisor's source checkout, where a session about ProVisor
    /// itself is opened; empty when none is set. It is used only once
    /// `ProVisorHome.sourceFolder(at:)` finds the source there.
    @Published public var provisorSourceFolder: String {
        didSet { defaults.set(provisorSourceFolder, forKey: Key.provisorSourceFolder) }
    }

    /// ProVisor: whether the app keeps a copy of the person's recent direct messages from the
    /// source they signed in to. Off by default: it holds a signed-in session and other
    /// people's messages.
    @Published public var provisorReadsDirectMessages: Bool {
        didSet { defaults.set(provisorReadsDirectMessages, forKey: Key.provisorReadDirectMessages) }
    }

    /// Per-module enabled flags, keyed by `moduleID`. Absent ids default to enabled, except
    /// opt-in modules.
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
        self.swarmShowsMessages =
            (defaults.object(forKey: Key.swarmShowMessages) as? Bool) ?? false
        self.swarmJumpHotKeyEnabled =
            (defaults.object(forKey: Key.swarmJumpHotKey) as? Bool) ?? true
        // Read as an object, not `integer(forKey:)`: 0 is a real choice here, and an absent key
        // must not be mistaken for it.
        let storedScoutHours = defaults.object(forKey: Key.provisorScoutHours) as? Int
        self.provisorScoutHours = storedScoutHours
            .flatMap { Self.provisorScoutHourChoices.contains($0) ? $0 : nil } ?? 6
        self.provisorReadsTexts =
            (defaults.object(forKey: Key.provisorReadTexts) as? Bool) ?? false
        self.provisorOffersPasswords =
            (defaults.object(forKey: Key.provisorOfferPasswords) as? Bool) ?? true
        self.provisorReadsPhotoPlaces =
            (defaults.object(forKey: Key.provisorReadPhotoPlaces) as? Bool) ?? false
        self.provisorSourceFolder =
            (defaults.object(forKey: Key.provisorSourceFolder) as? String) ?? ""
        self.provisorReadsDirectMessages =
            (defaults.object(forKey: Key.provisorReadDirectMessages) as? Bool) ?? false

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

    /// Whether a module is enabled. Unknown ids default to `true`, opt-in modules to `false`.
    public func isEnabled(_ moduleID: String) -> Bool {
        moduleEnabled[moduleID] ?? !Self.optInModules.contains(moduleID)
    }

    /// Set a module's enabled flag and persist it.
    public func setEnabled(_ enabled: Bool, for moduleID: String) {
        moduleEnabled[moduleID] = enabled
        defaults.set(enabled, forKey: Key.moduleEnabledPrefix + moduleID)
    }

    /// Ensure an entry exists for a module id so the settings UI can render a toggle even
    /// before the user has changed it. Defaults to enabled, except for opt-in modules.
    public func registerModuleIfNeeded(_ moduleID: String) {
        if moduleEnabled[moduleID] == nil {
            moduleEnabled[moduleID] = !Self.optInModules.contains(moduleID)
        }
    }
}
