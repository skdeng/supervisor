import CoreAudio
import Foundation

/// Reads and controls the system audio output route via CoreAudio.
///
/// Exposes the current default output device and the list of output-capable devices, lets the
/// UI switch the system default output, and live-updates when the route or the device list
/// changes (e.g. AirPods connect, a display is unplugged). This is the same route the macOS
/// Control Center / Now-Playing output picker drives — switching it moves system audio, so
/// media playing through the default output follows it.
///
/// All published state is `@MainActor`-isolated. CoreAudio property listeners are registered to
/// deliver on the main queue, so their callbacks can update state directly.
@MainActor
final class AudioOutputController: ObservableObject {
    /// An output-capable audio device.
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    /// Output-capable devices currently available, in CoreAudio enumeration order.
    @Published private(set) var devices: [Device] = []
    /// The system default output device's id (`0` if none resolved).
    @Published private(set) var currentDeviceID: AudioDeviceID = 0

    /// Friendly name of the current output device, or empty when unknown.
    var currentName: String {
        devices.first { $0.id == currentDeviceID }?.name ?? ""
    }

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    /// Registered listeners, kept so they can be unregistered on `stop()`.
    private var listeners: [AudioPropertyListener] = []
    private var started = false

    // MARK: Lifecycle

    /// Read the current route and begin observing route / device-list changes.
    func start() {
        guard !started else { return }
        started = true
        refresh()
        addListener(for: kAudioHardwarePropertyDefaultOutputDevice)
        addListener(for: kAudioHardwarePropertyDevices)
    }

    /// Stop observing and release listeners.
    func stop() {
        for listener in listeners { listener.invalidate() }
        listeners.removeAll()
        started = false
    }

    // MARK: Actions

    /// Make `id` the system default output device. The change is applied immediately and
    /// confirmed by the default-device listener; we also update optimistically so the UI
    /// reflects the selection without waiting for the callback.
    func select(_ id: AudioDeviceID) {
        guard id != currentDeviceID else { return }
        setDefaultOutputDevice(id)
        currentDeviceID = id
    }

    // MARK: Refresh

    private func refresh() {
        devices = outputDevices()
        currentDeviceID = defaultOutputDevice()
    }

    private func addListener(for selector: AudioObjectPropertySelector) {
        let address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let listener = AudioPropertyListener(objectID: systemObject, address: address, onChange: { [weak self] in
            self?.refresh()
        }) {
            listeners.append(listener)
        }
    }

    // MARK: CoreAudio queries

    private func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func setDefaultOutputDevice(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        AudioObjectSetPropertyData(
            systemObject, &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
    }

    private func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
            .filter(isOutputDevice)
            .map { Device(id: $0, name: deviceName($0)) }
    }

    /// A device qualifies as an output if it exposes at least one output channel.
    private func isOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        for buffer in bufferList where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return "Unknown Device" }
        return name.takeRetainedValue() as String
    }
}
