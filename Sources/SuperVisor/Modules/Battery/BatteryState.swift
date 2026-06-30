import Foundation

/// Power-source state for the internal battery, derived from IOKit's IOPowerSources API.
///
/// All values are a snapshot computed off the main actor and then published onto the main
/// actor by `BatteryModule`. `isPresent` is false on machines without an internal battery
/// (e.g. a Mac mini/Studio) so the module can degrade to a Bluetooth-only contribution.
struct BatteryState: Equatable {
    /// Whether an internal battery power source exists at all.
    var isPresent: Bool = false
    /// Current charge as a fraction 0...1, or nil when unknown.
    var fraction: Double? = nil
    /// Whether the battery is actively charging from wall power.
    var isCharging: Bool = false
    /// Whether the battery is full / charged while plugged in.
    var isCharged: Bool = false
    /// Whether the machine is drawing from AC power (charging, charged, or topped off).
    var isPluggedIn: Bool = false
    /// Estimated seconds until full when charging, or until empty when on battery.
    /// nil when the system is still calculating ("Calculating…") or the value is unknown.
    var secondsRemaining: Int? = nil

    /// Integer percentage 0...100 for display, or nil when unknown.
    var percent: Int? {
        guard let fraction else { return nil }
        return Int((fraction * 100).rounded())
    }

    /// Whether the charge has dropped to the warning threshold while on battery.
    var isLow: Bool {
        guard !isPluggedIn, let p = percent else { return false }
        return p <= 20
    }

    /// Whether the charge has dropped to the critical threshold while on battery.
    var isCritical: Bool {
        guard !isPluggedIn, let p = percent else { return false }
        return p <= 10
    }
}

/// The thresholds at which a low-battery peek fires. Crossing a threshold downward (and not
/// while plugged in) triggers exactly one alert per crossing.
enum BatteryThreshold: Int, CaseIterable {
    case low = 20
    case critical = 10
}

/// A connected Bluetooth device the module surfaces, with its name and — where the device
/// publishes it via the BatteryPercent IORegistry property — a battery level.
struct BluetoothDeviceInfo: Identifiable, Equatable {
    /// Stable identity: the device's address string (falls back to name).
    let id: String
    /// Display name reported by the device.
    let name: String
    /// Battery level as a fraction 0...1, or nil when the device does not report one.
    let batteryFraction: Double?

    /// Integer battery percentage for display, or nil when unknown.
    var batteryPercent: Int? {
        guard let batteryFraction else { return nil }
        return Int((batteryFraction * 100).rounded())
    }
}
