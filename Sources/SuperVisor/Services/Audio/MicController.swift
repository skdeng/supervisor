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
/// A mute this controller applies is remembered per device, so it can be undone on the exact
/// device it was applied to even after the system default input changes, and is *carried* to a
/// new default input so a mid-call device switch (e.g. AirPods connect) never silently un-mutes
/// you or leaves the previous device muted for every app.
///
/// All published state is `@MainActor`. CoreAudio listeners are registered through
/// `AudioPropertyListener` (the proc-based API) and deliver on the main actor.
@MainActor
final class MicController: ObservableObject {
    /// Whether the default input device is currently muted.
    @Published private(set) var isMuted = false
    /// Whether there is a usable default input device at all.
    @Published private(set) var hasInput = false

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var deviceID = AudioDeviceID(0)
    private var started = false
    private var defaultInputListener: AudioPropertyListener?
    private var deviceListeners: [AudioPropertyListener] = []

    /// A mute this controller applied, retained so it can be undone on the precise device it
    /// targeted — even after the default input changes.
    private struct AppliedMute {
        let device: AudioDeviceID
        let viaVolume: Bool
        /// The input volume captured before a volume-fallback mute, restored on unmute.
        let savedVolume: Float32?
    }
    private var appliedMute: AppliedMute?

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
        if muted {
            applyMute(on: deviceID)
        } else {
            clearMute(on: deviceID)
        }
        // Reflect what actually took effect, not what was requested — a device may not support
        // either control, in which case the indicator must not claim a mute that didn't happen.
        refreshMuted()
    }

    // MARK: Device binding

    /// Bind to the current default input device, (re)attaching the property listeners. Called on
    /// start and whenever the default input changes. If a mute we applied is outstanding, it is
    /// undone on the departing device and re-applied to the new one, so the mute follows you
    /// across a device switch and never orphans a system-wide mute on the old device.
    private func bindToDefaultInput() {
        let newDevice = defaultInputDevice()
        let carryMute = appliedMute != nil

        // Release our mute on the departing device so it isn't left hardware-muted for every app.
        if let applied = appliedMute, applied.device != newDevice {
            undo(applied)
            appliedMute = nil
        }

        removeDeviceListeners()
        deviceID = newDevice
        hasInput = deviceID != 0
        addDeviceListeners()

        // Carry an in-progress mute to the new default input BEFORE publishing, so a device
        // switch mid-mute never surfaces a transient un-muted state.
        if carryMute, deviceID != 0, appliedMute == nil {
            applyMute(on: deviceID)
        }
        refreshMuted()
    }

    private func addDefaultInputListener() {
        defaultInputListener = AudioPropertyListener(
            objectID: systemObject,
            address: systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        ) { [weak self] in self?.bindToDefaultInput() }
    }

    private func removeDefaultInputListener() {
        defaultInputListener?.invalidate()
        defaultInputListener = nil
    }

    /// Listen on BOTH the mute property and the input volume so the published state stays true
    /// however the mic was (un)silenced — including the volume fallback path and changes made by
    /// other apps.
    private func addDeviceListeners() {
        guard deviceID != 0 else { return }
        deviceListeners = [muteAddress(), volumeAddress()].compactMap { address in
            AudioPropertyListener(objectID: deviceID, address: address) { [weak self] in
                self?.refreshMuted()
            }
        }
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners { listener.invalidate() }
        deviceListeners.removeAll()
    }

    // MARK: Mute application

    /// Mute `device` via its settable mute property when it has one, otherwise by zeroing input
    /// volume (saving the prior level). Records what was done so it can be undone precisely.
    private func applyMute(on device: AudioDeviceID) {
        guard device != 0, appliedMute == nil else { return }
        if hasSettableMute(device) {
            setMuteProperty(true, on: device)
            appliedMute = AppliedMute(device: device, viaVolume: false, savedVolume: nil)
        } else if let saved = muteViaVolume(device) {
            appliedMute = AppliedMute(device: device, viaVolume: true, savedVolume: saved)
        }
    }

    /// Undo our applied mute (restoring the exact saved volume for the volume fallback), then
    /// lift any residual mute-property still set on the current device so unmute is never a no-op.
    /// A low input volume the user set themselves is left untouched.
    private func clearMute(on device: AudioDeviceID) {
        if let applied = appliedMute {
            undo(applied)
            appliedMute = nil
        }
        if hasSettableMute(device), muteProperty(of: device) == true {
            setMuteProperty(false, on: device)
        }
    }

    private func undo(_ applied: AppliedMute) {
        guard applied.device != 0 else { return }
        if applied.viaVolume {
            setInputVolume(applied.savedVolume ?? 1, on: applied.device)
        } else {
            setMuteProperty(false, on: applied.device)
        }
    }

    /// Re-read the current device's mute state and publish it. A device that reads un-muted means
    /// no mute is held on it, so any stale applied-mute record (e.g. an external unmute) is dropped.
    private func refreshMuted() {
        let muted = deviceIsMuted(deviceID)
        if !muted { appliedMute = nil }
        if muted != isMuted { isMuted = muted }
    }

    // MARK: CoreAudio queries

    private func defaultInputDevice() -> AudioDeviceID {
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id)
        return id
    }

    private func hasSettableMute(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// The device's mute-property value, or `nil` when the device exposes no mute property.
    private func muteProperty(of device: AudioDeviceID) -> Bool? {
        guard device != 0 else { return nil }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    /// Whether `device` is muted. A device that exposes a mute property is muted iff that
    /// property is set — a low input *volume* the user chose is not a mute. A device without a
    /// mute property uses volume as its only mute mechanism, so there a near-zero volume counts.
    private func deviceIsMuted(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        if let mute = muteProperty(of: device) {
            return mute
        }
        if let volume = inputVolume(of: device), volume <= 0.0001 {
            return true
        }
        return false
    }

    private func setMuteProperty(_ muted: Bool, on device: AudioDeviceID) {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Volume fallback (devices without a settable mute property)

    private func inputVolume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private func setInputVolume(_ value: Float32, on device: AudioDeviceID) {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var v = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    /// Zero the input volume to mute, returning the prior level to restore later — or `nil` when
    /// the device's volume isn't settable (so no volume-based mute is possible).
    private func muteViaVolume(_ device: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        let prior = inputVolume(of: device) ?? 1
        setInputVolume(0, on: device)
        return prior
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
