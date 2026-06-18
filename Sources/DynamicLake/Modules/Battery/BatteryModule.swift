import SwiftUI
import Combine

/// Power & connectivity module: internal-battery status plus Bluetooth device presence and
/// battery levels.
///
/// - Battery state comes from `PowerSourceMonitor` (IOKit IOPowerSources, live via an
///   `IOPSNotificationCreateRunLoopSource`). The module peeks on plug/unplug and when the
///   charge crosses the 20% and 10% thresholds downward while on battery.
/// - Bluetooth comes from `BluetoothMonitor` (IOBluetooth connect/disconnect notifications),
///   with accessory battery levels read from the IORegistry. The module peeks on
///   connect/disconnect and briefly shows a Bluetooth glyph in the compact pill.
///
/// Compact trailing shows a battery ring whenever the battery is low or charging, and a
/// short-lived Bluetooth glyph right after a connect/disconnect. The expanded section renders
/// a `BatteryStatusCard`.
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
    /// Whether the battery ring was contributing on the last compact evaluation, so we only
    /// ask the engine to re-lay-out when that actually flips.
    private var hadCompactContribution = false

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
            Task { @MainActor in self?.devices = devices }
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
        refreshCompactContributionIfNeeded()
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

    // MARK: Compact contribution bookkeeping

    /// Whether the compact pill currently has anything from this module on the trailing side.
    private var contributesCompact: Bool {
        compactBatteryVisible
    }

    /// Whether the battery ring should appear: when low/critical or actively charging.
    private var compactBatteryVisible: Bool {
        battery.isPresent && (battery.isLow || battery.isCritical || battery.isCharging)
    }

    /// Tell the engine to re-lay-out the pill only when our compact contribution appears or
    /// disappears (per the NotchContext contract).
    private func refreshCompactContributionIfNeeded() {
        let now = contributesCompact
        if now != hadCompactContribution {
            hadCompactContribution = now
            context?.setNeedsCompactRefresh()
        }
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

    func compactTrailing() -> AnyView? {
        // A transient Bluetooth glyph wins the slot briefly; otherwise the battery ring when
        // low or charging. Contribute NOTHING when idle/healthy — otherwise the pill keeps a
        // reserved padded slot and never shrinks fully back to the notch.
        guard contributesCompact else { return nil }
        return AnyView(CompactTrailing(module: self))
    }

    func expandedSection() -> AnyView? {
        AnyView(ExpandedSection(module: self))
    }

    // MARK: View wrappers (observe the module so they update live)

    private struct CompactTrailing: View {
        @ObservedObject var module: BatteryModule

        var body: some View {
            if module.compactBatteryVisible {
                BatteryRingView(
                    fraction: module.battery.fraction ?? 0,
                    isCharging: module.battery.isCharging,
                    tint: module.batteryTint
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

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
