import SwiftUI
import Combine

/// Power & connectivity module: internal-battery status plus Bluetooth device presence and
/// battery levels.
///
/// - Battery state comes from `PowerSourceMonitor` (IOKit IOPowerSources, live via an
///   `IOPSNotificationCreateRunLoopSource`). The module peeks on plug/unplug and when the
///   charge crosses the 20% and 10% thresholds downward while on battery.
/// - Bluetooth comes from `BluetoothMonitor` (IOBluetooth connect/disconnect notifications),
///   with accessory battery levels read from the IORegistry.
///
/// The module has no compact-pill presence; it peeks the notch on plug/unplug and on low/critical
/// battery, and the expanded section renders a `BatteryStatusCard`.
@MainActor
final class BatteryModule: NotchModule, ObservableObject {
    let moduleID = "battery"
    let displayName = "Battery"
    let order = 50

    // MARK: Published UI state

    @Published private var battery = BatteryState()
    @Published private var devices: [BluetoothDeviceInfo] = []

    // MARK: Collaborators

    private var context: NotchContext?
    private let powerMonitor = PowerSourceMonitor()
    private let bluetoothMonitor = BluetoothMonitor()

    /// Lowest battery threshold already alerted for the current discharge run; reset on plug-in
    /// so the next discharge re-alerts. Stored as the threshold's raw percentage.
    private var lastAlertedThreshold: Int?
    /// Previous plugged-in state, to detect plug/unplug edges.
    private var wasPluggedIn: Bool?

    // MARK: NotchModule

    func activate(_ context: NotchContext) {
        self.context = context

        // Power source: callback arrives on the main run loop; mutate state directly.
        powerMonitor.onChange = { [weak self] state in
            MainActor.assumeIsolated {
                self?.applyBatteryState(state)
            }
        }
        powerMonitor.start()

        // Bluetooth: only track the connected-device list for the expanded status card; the
        // compact pill shows no connect/disconnect indicator. Selectors fire on the main
        // thread; hop explicitly to satisfy main-actor isolation of UI state.
        bluetoothMonitor.onChange = { [weak self] devices in
            MainActor.assumeIsolated {
                self?.devices = devices
            }
        }
        bluetoothMonitor.start()
    }

    func deactivate() {
        powerMonitor.stop()
        bluetoothMonitor.stop()
        context = nil
    }

    // MARK: Battery handling

    private func applyBatteryState(_ new: BatteryState) {
        let previous = battery
        battery = new

        detectThresholdCrossings(previous: previous, new: new)
        detectPowerSourceChange(previous: previous, new: new)
    }

    /// Fire a low/critical peek exactly once per downward crossing while on battery. Reset the
    /// alert latch whenever we go back on AC power.
    private func detectThresholdCrossings(previous: BatteryState, new: BatteryState) {
        if new.isPluggedIn {
            lastAlertedThreshold = nil
            return
        }
        guard let percent = new.percent else { return }

        // The most severe (lowest) threshold currently breached, e.g. 10 when at 8%.
        let breached = BatteryThreshold.allCases
            .map(\.rawValue)
            .filter { percent <= $0 }
            .min()

        guard let breached else {
            // Charge recovered above all thresholds; clear the latch so a later dip re-alerts.
            lastAlertedThreshold = nil
            return
        }

        // Alert when newly breached, or when crossing to a more severe threshold than last.
        if breached < (lastAlertedThreshold ?? Int.max) {
            lastAlertedThreshold = breached
            context?.requestPeek(4)
        }
    }

    /// Peek when the machine is plugged in or unplugged.
    private func detectPowerSourceChange(previous: BatteryState, new: BatteryState) {
        defer { wasPluggedIn = new.isPluggedIn }
        guard let was = wasPluggedIn, was != new.isPluggedIn, new.isPresent else { return }
        context?.requestPeek(3)
    }

    // MARK: Tints

    /// Tint reflecting battery state for rings/cards.
    private var batteryTint: Color {
        if battery.isCharging || (battery.isCharged && battery.isPluggedIn) { return .green }
        if battery.isCritical { return .red }
        if battery.isLow { return .orange }
        return .white
    }

    // MARK: UI contributions

    func expandedSection() -> AnyView? {
        AnyView(ExpandedSection(module: self))
    }

    // MARK: View wrappers (observe the module so they update live)

    private struct ExpandedSection: View {
        @ObservedObject var module: BatteryModule

        var body: some View {
            BatteryStatusCard(
                battery: module.battery,
                devices: module.devices,
                tint: module.batteryTint
            )
        }
    }
}
