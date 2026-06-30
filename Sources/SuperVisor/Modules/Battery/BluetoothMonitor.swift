import Foundation
import IOBluetooth
import IOKit

/// Observes Bluetooth device connect/disconnect and publishes the set of currently connected
/// devices with names and, where available, battery levels.
///
/// Connect events use the global `IOBluetoothDevice.register(forConnectNotifications:…)`.
/// Disconnect is per-device, so on each connect we install a one-shot disconnect notification
/// for that device. Battery levels are sourced from the IORegistry — Apple HID accessories
/// (AirPods, Magic Mouse/Trackpad/Keyboard) publish `BatteryPercent` (and split L/R/case
/// keys) on their `AppleDeviceManagementHIDEventService` / HID entries.
///
/// This is an `NSObject` because IOBluetooth notification targets are Objective-C selectors.
/// It is not main-actor isolated; it forwards changes to the module via the `onConnect`,
/// `onDisconnect`, and `onChange` closures, which the module hops onto the main actor.
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

    /// Begin observing. Registers for connect notifications and seeds the current list from
    /// already-connected paired devices.
    func start() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )

        // Seed from paired devices that are already connected, and arm disconnect
        // notifications for each so we observe their drops.
        for device in pairedConnectedDevices() {
            armDisconnect(for: device)
        }
        emitChange()
    }

    /// Tear down all notifications.
    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for (_, note) in disconnectNotifications {
            note.unregister()
        }
        disconnectNotifications.removeAll()
        onConnect = nil
        onDisconnect = nil
        onChange = nil
    }

    // MARK: - IOBluetooth callbacks

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification,
                                       device: IOBluetoothDevice) {
        armDisconnect(for: device)
        let info = makeInfo(for: device)
        onConnect?(info)
        emitChange()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification,
                                          device: IOBluetoothDevice) {
        notification.unregister()
        let key = device.addressString ?? (device.name ?? "")
        disconnectNotifications.removeValue(forKey: key)
        onDisconnect?(device.name ?? "Bluetooth Device")
        emitChange()
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

    /// Snapshot the current connected-device list and deliver it.
    private func emitChange() {
        let devices = pairedConnectedDevices().map { makeInfo(for: $0) }
        onChange?(devices)
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
