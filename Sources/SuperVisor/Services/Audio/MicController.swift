import CoreAudio
import Foundation

/// Reads and controls the system microphone (the default audio *input* device) via CoreAudio.
///
/// Muting toggles the input device's hardware mute at the HAL level, so it silences the mic for
/// every app (a true global mute), independent of any in-app software mute. Controlling the
/// device — as opposed to *capturing* it — needs no microphone permission and does not trip the
/// macOS recording indicator. Devices without a settable mute property fall back to zeroing the
/// input volume (restored on unmute).
///
/// All published state is `@MainActor`. CoreAudio listeners are registered to deliver on the
/// main queue, so their callbacks update state directly.
@MainActor
final class MicController: ObservableObject {
    /// Whether the default input device is currently muted.
    @Published private(set) var isMuted = false
    /// Whether there is a usable default input device at all.
    @Published private(set) var hasInput = false

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var deviceID = AudioDeviceID(0)
    private var started = false
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    /// Input volume saved before a volume-fallback mute, restored on unmute.
    private var savedVolume: Float32?

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        bindToDefaultInput()
        addDefaultInputListener()
    }

    func stop() {
        removeDefaultInputListener()
        removeDeviceListeners()
        started = false
    }

    // MARK: Actions

    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        guard deviceID != 0 else { return }
        if muteIsSettable() {
            setMuteProperty(muted)
        } else {
            setMutedViaVolume(muted)
        }
        // Reflect what actually took effect, not what was requested — a device may not support
        // either control, in which case the indicator must not claim a mute that didn't happen.
        isMuted = readMuted()
    }

    // MARK: Device binding

    /// Bind to the current default input device, reading its mute state and (re)attaching the
    /// property listeners. Called on start and whenever the default input device changes.
    private func bindToDefaultInput() {
        removeDeviceListeners()
        deviceID = defaultInputDevice()
        hasInput = deviceID != 0
        savedVolume = nil          // volume save belongs to the previous device; drop it
        isMuted = readMuted()
        addDeviceListeners()
    }

    private func addDefaultInputListener() {
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindToDefaultInput() }
        }
        if AudioObjectAddPropertyListenerBlock(systemObject, &address, DispatchQueue.main, block) == noErr {
            defaultInputListener = block
        }
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListener else { return }
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(systemObject, &address, DispatchQueue.main, block)
        defaultInputListener = nil
    }

    /// Listen on BOTH the mute property and the input volume so the published state stays true
    /// however the mic was (un)silenced — including the volume fallback path and changes made by
    /// other apps.
    private func addDeviceListeners() {
        guard deviceID != 0 else { return }
        muteListener = addListener(muteAddress())
        volumeListener = addListener(volumeAddress())
    }

    private func removeDeviceListeners() {
        if let block = muteListener, deviceID != 0 {
            var address = muteAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        muteListener = nil
        if let block = volumeListener, deviceID != 0 {
            var address = volumeAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        volumeListener = nil
    }

    private func addListener(_ address: AudioObjectPropertyAddress) -> AudioObjectPropertyListenerBlock? {
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.isMuted = self?.readMuted() ?? false }
        }
        return AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block) == noErr ? block : nil
    }

    // MARK: CoreAudio queries

    private func defaultInputDevice() -> AudioDeviceID {
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id)
        return id
    }

    private func muteIsSettable() -> Bool {
        guard deviceID != 0 else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    /// Muted if the mute property is set, OR the input volume is effectively zero — so a mute
    /// applied through either mechanism (or by another app) is reported faithfully.
    private func readMuted() -> Bool {
        guard deviceID != 0 else { return false }
        var address = muteAddress()
        if AudioObjectHasProperty(deviceID, &address) {
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr, muted != 0 {
                return true
            }
        }
        if let volume = inputVolume(), volume <= 0.0001 {
            return true
        }
        return false
    }

    private func setMuteProperty(_ muted: Bool) {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Volume fallback (devices without a settable mute property)

    private func inputVolume() -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private func setMutedViaVolume(_ muted: Bool) {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { return }
        var value: Float32
        if muted {
            savedVolume = inputVolume()
            value = 0
        } else {
            value = savedVolume ?? 1
            savedVolume = nil
        }
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    // MARK: Address helpers

    private func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
