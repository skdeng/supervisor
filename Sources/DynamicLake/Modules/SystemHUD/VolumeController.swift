import CoreAudio
import Foundation

/// Reads, writes, and observes the system output volume via CoreAudio.
///
/// The "system volume" is the master scalar volume of the *default output device*. Because
/// the default device can change at runtime (e.g. plugging in headphones), this controller
/// re-resolves the device and re-installs its listeners whenever the default output device
/// property changes.
///
/// Volume is exposed as a `Float` in `0...1`. Some devices do not implement a master
/// `kAudioDevicePropertyVolumeScalar` element (element 0); for those we fall back to the
/// average of the per-channel scalar volumes (channels 1 and 2 of the preferred stereo
/// pair). Muting is read/written through `kAudioDevicePropertyMute`.
///
/// All public callbacks are delivered on the main actor.
final class VolumeController: @unchecked Sendable {
    /// Called whenever the volume scalar (`0...1`) or mute state changes, on the main actor.
    var onChange: (@MainActor @Sendable (_ volume: Float, _ muted: Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.dynamiclake.systemhud.volume")

    /// The currently observed default output device.
    private var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// Listener block kept alive for the lifetime of the controller so it can be removed.
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// The preferred stereo channels for per-channel fallback (typically [1, 2]).
    private var stereoChannels: [UInt32] = [1, 2]

    // MARK: System object address (for default-device changes)

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.installDefaultDeviceListener()
            self.resolveDefaultDevice()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownDeviceListeners()
            var address = self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, self.queue, self.systemListenerBlock
            )
        }
    }

    // MARK: Public reads/writes (thread-safe; perform synchronously off main where possible)

    /// Sets the system output volume (`0...1`). Writes the master element when available,
    /// otherwise writes each stereo channel. Setting a non-zero volume also unmutes.
    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        queue.async { [weak self] in
            guard let self else { return }
            let dev = self.deviceID
            guard dev != AudioObjectID(kAudioObjectUnknown) else { return }

            if clamped > 0 { self.writeMute(false, device: dev) }

            if self.hasMasterVolume(device: dev) {
                self.writeScalar(clamped, device: dev, channel: 0)
            } else {
                for ch in self.stereoChannels {
                    self.writeScalar(clamped, device: dev, channel: ch)
                }
            }
        }
    }

    /// Sets the mute state of the default output device.
    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeMute(muted, device: self.deviceID)
        }
    }

    // MARK: Default-device resolution

    private lazy var systemListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.resolveDefaultDevice()
    }

    private func installDefaultDeviceListener() {
        var address = defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, systemListenerBlock
        )
    }

    private func resolveDefaultDevice() {
        teardownDeviceListeners()

        var address = defaultDeviceAddress
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &newDevice
        )
        guard status == noErr, newDevice != AudioObjectID(kAudioObjectUnknown) else {
            deviceID = AudioObjectID(kAudioObjectUnknown)
            return
        }
        deviceID = newDevice
        resolvePreferredStereoChannels(device: newDevice)
        installDeviceListeners(device: newDevice)
        emitCurrent()
    }

    private func resolvePreferredStereoChannels(device: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels)
        if status == noErr { stereoChannels = channels }
    }

    // MARK: Device property listeners

    private func installDeviceListeners(device: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emitCurrent()
        }
        deviceListener = block

        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for scope in [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput] {
                for element in stereoChannelsForListening() {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector, mScope: scope, mElement: element
                    )
                    AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
                }
            }
        }
    }

    private func teardownDeviceListeners() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown), let block = deviceListener else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for scope in [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput] {
                for element in stereoChannelsForListening() {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector, mScope: scope, mElement: element
                    )
                    AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
                }
            }
        }
        deviceListener = nil
    }

    /// Elements we listen on: master (0) plus each stereo channel.
    private func stereoChannelsForListening() -> [UInt32] {
        [0] + stereoChannels
    }

    // MARK: Scalar / mute helpers

    private func emitCurrent() {
        let dev = deviceID
        guard dev != AudioObjectID(kAudioObjectUnknown) else { return }
        let vol = readVolume(device: dev)
        let muted = readMute(device: dev)
        guard let cb = onChange else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(vol, muted) } }
    }

    private func readVolume(device: AudioObjectID) -> Float {
        if hasMasterVolume(device: device), let v = readScalar(device: device, channel: 0) {
            return v
        }
        var sum: Float = 0
        var count: Float = 0
        for ch in stereoChannels {
            if let v = readScalar(device: device, channel: ch) {
                sum += v
                count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }

    private func hasMasterVolume(device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        return AudioObjectHasProperty(device, &address)
    }

    private func readScalar(device: AudioObjectID, channel: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func writeScalar(_ value: Float, device: AudioObjectID, channel: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var v = Float32(value)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private func readMute(device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func writeMute(_ muted: Bool, device: AudioObjectID) {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}
