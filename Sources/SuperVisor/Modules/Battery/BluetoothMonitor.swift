import Foundation
import IOBluetooth
import IOKit

/// Observes Bluetooth device connect/disconnect and publishes the set of currently connected
/// devices with names and, where available, battery levels.
///
/// Connect events use the global `IOBluetoothDevice.register(forConnectNotifications:…)`.
/// Disconnect is per-device, so connected devices each get a one-shot disconnect
/// notification. Battery levels are sourced from the IORegistry — Apple HID accessories
/// (AirPods, Magic Mouse/Trackpad/Keyboard) publish `BatteryPercent` (and split L/R/case
/// keys) on their `AppleDeviceManagementHIDEventService` / HID entries.
///
/// This is an `NSObject` because IOBluetooth notification targets are Objective-C selectors.
///
/// Threading: IOBluetooth is not main-thread-honest. Classic connect/disconnect
/// notifications arrive on the main run loop, but BLE connection events are posted from the
/// framework's own coordinator queue (`com.apple.bluetooth.iobluetooth.coordinatorQueue`) —
/// crash reports show both a data race on the notification dictionary (EXC_BAD_ACCESS in the
/// callback path) and, with the callbacks main-actor-isolated instead, the @objc thunk's
/// isolation assert trapping on that queue. All state on this class is therefore main-actor
/// isolated, and the notification callbacks are `nonisolated` trampolines that do nothing on
/// the delivering thread but bounce to the main actor — they never read the passed device
/// (a fresh paired-device query on the main actor re-derives everything) and identify spent
/// disconnect registrations by object identity only.
@MainActor
final class BluetoothMonitor: NSObject {
    /// Fired when a device connects, with the freshly-read device info.
    var onConnect: ((BluetoothDeviceInfo) -> Void)?
    /// Fired when a device disconnects, with the device name.
    var onDisconnect: ((String) -> Void)?
    /// Fired with the full current connected-device list after any change.
    var onChange: (([BluetoothDeviceInfo]) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    /// Disconnect notifications keyed by device address so we can drop them on disconnect.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// The device list as of the last resync, diffed to announce connects/disconnects.
    private var lastSnapshot: [BluetoothDeviceInfo] = []
    /// Coalesces notification bursts (registration replays every connected device, and BLE
    /// events can arrive in clusters) into one pending resync.
    private var resyncScheduled = false
    private var isRunning = false

    /// Begin observing. Registers for connect notifications and seeds the current list from
    /// already-connected paired devices. Registration synchronously replays every connected
    /// device into `deviceConnected` before returning; that replay is harmless because the
    /// callback only schedules a resync.
    func start() {
        isRunning = true
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        resync(announceDiff: false)
    }

    /// Tear down all notifications.
    func stop() {
        isRunning = false
        connectNotification?.unregister()
        connectNotification = nil
        for (_, note) in disconnectNotifications {
            note.unregister()
        }
        disconnectNotifications.removeAll()
        lastSnapshot = []
        onConnect = nil
        onDisconnect = nil
        onChange = nil
    }

    // MARK: - IOBluetooth callbacks (nonisolated trampolines — no work off the main actor)

    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification?,
                                                   device: IOBluetoothDevice?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleResync()
            }
        }
    }

    @objc nonisolated private func deviceDisconnected(_ notification: IOBluetoothUserNotification?,
                                                      device: IOBluetoothDevice?) {
        // Identify the spent one-shot registration by identity alone; the stored reference
        // (the same object) is unregistered on the main actor.
        let spent = notification.map(ObjectIdentifier.init)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.retireDisconnectNotification(spent)
                self?.scheduleResync()
            }
        }
    }

    // MARK: - Resync

    private func retireDisconnectNotification(_ identity: ObjectIdentifier?) {
        guard let identity else { return }
        for (key, note) in disconnectNotifications where ObjectIdentifier(note) == identity {
            note.unregister()
            disconnectNotifications.removeValue(forKey: key)
        }
    }

    private func scheduleResync() {
        guard isRunning, !resyncScheduled else { return }
        resyncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resyncScheduled = false
            guard self.isRunning else { return }
            self.resync(announceDiff: true)
        }
    }

    /// Re-derive state from a fresh paired-device query: arm disconnect notifications for
    /// connected devices, announce the diff against the previous snapshot, and publish the
    /// full list.
    private func resync(announceDiff: Bool) {
        let devices = pairedConnectedDevices()
        for device in devices {
            armDisconnect(for: device)
        }

        let infos = devices.map { makeInfo(for: $0) }
        let previous = lastSnapshot
        lastSnapshot = infos

        if announceDiff {
            let previousIDs = Set(previous.map(\.id))
            let currentIDs = Set(infos.map(\.id))
            for info in infos where !previousIDs.contains(info.id) {
                onConnect?(info)
            }
            for info in previous where !currentIDs.contains(info.id) {
                onDisconnect?(info.name)
            }
        }
        onChange?(infos)
    }

    // MARK: - Helpers

    private func armDisconnect(for device: IOBluetoothDevice) {
        let key = device.addressString ?? (device.name ?? "")
        guard !key.isEmpty, disconnectNotifications[key] == nil else { return }
        if let note = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        ) {
            disconnectNotifications[key] = note
        }
    }

    /// All paired devices that report as currently connected.
    private func pairedConnectedDevices() -> [IOBluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }
        return paired.filter { $0.isConnected() }
    }

    private func makeInfo(for device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        let address = device.addressString ?? device.name ?? UUID().uuidString
        let name = device.name ?? "Bluetooth Device"
        let battery = BluetoothBatteryReader.batteryFraction(forName: name, address: address)
        return BluetoothDeviceInfo(id: address, name: name, batteryFraction: battery)
    }
}

/// Reads Bluetooth-accessory battery levels from the IORegistry.
///
/// Apple wireless accessories publish their battery level as an integer percentage under
/// well-known property keys on their HID event-service entries. We scan the relevant service
/// classes, match on product name, and return the best available reading (preferring a
/// combined level, then the lower of left/right for earbuds).
enum BluetoothBatteryReader {
    /// IORegistry property keys that carry a battery percentage (0...100), in priority order.
    private static let combinedKeys = ["BatteryPercentCombined", "BatteryPercent"]
    private static let splitKeys = ["BatteryPercentLeft", "BatteryPercentRight", "BatteryPercentCase"]

    /// Service classes that expose accessory battery levels.
    private static let serviceClasses = [
        "AppleDeviceManagementHIDEventService",
        "BNBMouseDevice",
        "AppleHSBluetoothDevice",
        "BNBTrackpadDevice",
    ]

    /// Best-effort battery fraction (0...1) for the accessory matching `name`/`address`, or
    /// nil when no reading is published.
    static func batteryFraction(forName name: String, address: String) -> Double? {
        let normalizedAddress = address.replacingOccurrences(of: ":", with: "-").lowercased()

        for serviceClass in serviceClasses {
            guard let matching = IOServiceMatching(serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                    == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                defer {
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(iterator)
                }

                guard matchesDevice(entry, name: name, normalizedAddress: normalizedAddress)
                else { continue }

                if let percent = readPercent(entry) {
                    return Double(percent) / 100.0
                }
            }
        }
        return nil
    }

    /// Whether an IORegistry entry corresponds to the given device, by product name or by the
    /// device-address property the HID service publishes.
    private static func matchesDevice(_ entry: io_registry_entry_t,
                                      name: String,
                                      normalizedAddress: String) -> Bool {
        if let product = stringProperty(entry, "Product"),
           product.caseInsensitiveCompare(name) == .orderedSame {
            return true
        }
        for key in ["DeviceAddress", "BD_ADDR", "address"] {
            if let value = stringProperty(entry, key)?
                .replacingOccurrences(of: ":", with: "-").lowercased(),
               value == normalizedAddress {
                return true
            }
        }
        return false
    }

    /// Read the best battery percentage from an entry: a combined/whole reading if present,
    /// else the minimum of the split (left/right/case) readings.
    private static func readPercent(_ entry: io_registry_entry_t) -> Int? {
        for key in combinedKeys {
            if let value = intProperty(entry, key), value > 0 {
                return min(100, value)
            }
        }
        let splits = splitKeys.compactMap { intProperty(entry, $0) }.filter { $0 > 0 }
        if let low = splits.min() {
            return min(100, low)
        }
        return nil
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return cf as? String
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (cf as? NSNumber)?.intValue
    }
}
