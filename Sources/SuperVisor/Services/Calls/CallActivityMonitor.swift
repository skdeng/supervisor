import Combine
import CoreAudio
import CoreMediaIO
import Foundation

/// Detects system-wide camera and microphone activity without opening either device.
///
/// CoreMediaIO and CoreAudio expose a `DeviceIsRunningSomewhere` property that reports whether
/// any process is using a device. Aggregate and virtual audio inputs are ignored unless they are
/// the current default input, which prevents SuperVisor's private spectrum-tap aggregate from
/// looking like microphone activity.
///
/// The shared instance starts on its first `retain()` and tears every listener down on its last
/// `release()`. A true signal is published after three continuous seconds and a false signal
/// after five continuous seconds. One cancellable task represents the pending transition; device
/// property listeners are the only steady-state wake source.
@MainActor
final class CallActivityMonitor: ObservableObject {
    static let shared = CallActivityMonitor()

    /// Camera use accepted by the call debounce.
    @Published private(set) var isCameraInUse = false
    /// Microphone use accepted by the call debounce after aggregate/virtual filtering.
    @Published private(set) var isMicInUse = false
    /// The first raw detection instant for the accepted call.
    @Published private(set) var callStartedAt: Date?

    /// Whether the accepted camera or microphone signal indicates an active call.
    var isCallLikely: Bool { isCameraInUse || micInUseIgnoringSelf }

    private var micInUseIgnoringSelf: Bool { isMicInUse }

    private let audioSystemObject = AudioObjectID(kAudioObjectSystemObject)
    private let cameraSystemObject = CMIOObjectID(kCMIOObjectSystemObject)

    private var retainCount = 0
    private var started = false

    private var cameraSystemListener: CMIOPropertyListener?
    private var cameraDeviceListeners: [CMIOPropertyListener] = []
    private var cameraDeviceIDs: [CMIODeviceID] = []

    private var audioSystemListeners: [AudioPropertyListener] = []
    private var audioDeviceListeners: [AudioPropertyListener] = []
    private var audioDeviceIDs: [AudioDeviceID] = []

    private var rawCameraInUse = false
    private var rawMicInUse = false
    private var rawSignalStartedAt: Date?
    private var pendingTarget: Bool?
    private var transitionTask: Task<Void, Never>?

    private init() {}

    // MARK: - Reference-counted lifecycle

    func retain() {
        retainCount += 1
        if retainCount == 1 {
            start()
        }
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        if retainCount == 0 {
            stop()
        }
    }

    private func start() {
        guard !started else { return }
        started = true

        cameraSystemListener = CMIOPropertyListener(
            objectID: cameraSystemObject,
            address: cameraAddress(kCMIOHardwarePropertyDevices)
        ) { [weak self] in
            self?.rebuildCameraDevices()
        }
        if cameraSystemListener == nil {
            AppLog.error(.calls, "CMIOPropertyListener init returned nil for camera system")
        }

        let audioDeviceListAddress = audioAddress(kAudioHardwarePropertyDevices)
        let defaultInputAddress = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        audioSystemListeners = [audioDeviceListAddress, defaultInputAddress].compactMap { address in
            let listener = AudioPropertyListener(
                objectID: audioSystemObject,
                address: address
            ) { [weak self] in
                self?.rebuildAudioDevices()
            }
            if listener == nil {
                AppLog.error(.calls, "AudioPropertyListener init returned nil for audio system")
            }
            return listener
        }

        rebuildCameraDevices()
        rebuildAudioDevices()
    }

    private func stop() {
        guard started else { return }
        started = false

        transitionTask?.cancel()
        transitionTask = nil
        pendingTarget = nil

        cameraSystemListener?.invalidate()
        cameraSystemListener = nil
        for listener in cameraDeviceListeners { listener.invalidate() }
        cameraDeviceListeners.removeAll()
        cameraDeviceIDs.removeAll()

        for listener in audioSystemListeners { listener.invalidate() }
        audioSystemListeners.removeAll()
        for listener in audioDeviceListeners { listener.invalidate() }
        audioDeviceListeners.removeAll()
        audioDeviceIDs.removeAll()

        rawCameraInUse = false
        rawMicInUse = false
        rawSignalStartedAt = nil
        callStartedAt = nil
        publishUsage(camera: false, microphone: false)
    }

    // MARK: - Camera detection

    private func rebuildCameraDevices() {
        for listener in cameraDeviceListeners { listener.invalidate() }
        cameraDeviceListeners.removeAll()

        cameraDeviceIDs = cameraDevices()
        let runningAddress = cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        cameraDeviceListeners = cameraDeviceIDs.compactMap { deviceID in
            let listener = CMIOPropertyListener(
                objectID: deviceID,
                address: runningAddress
            ) { [weak self] in
                self?.refreshCameraUsage()
            }
            if listener == nil {
                AppLog.error(
                    .calls,
                    "CMIOPropertyListener init returned nil for camera device \(deviceID)"
                )
            }
            return listener
        }
        refreshCameraUsage()
    }

    private func refreshCameraUsage() {
        rawCameraInUse = cameraDeviceIDs.contains(where: cameraIsRunning)
        reconcileDetectedUsage()
    }

    private func cameraDevices() -> [CMIODeviceID] {
        var address = cameraAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            cameraSystemObject, &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            cameraSystemObject, &address, 0, nil, size, &used, &deviceIDs
        ) == noErr else {
            return []
        }
        return deviceIDs.filter { $0 != 0 }
    }

    private func cameraIsRunning(_ deviceID: CMIODeviceID) -> Bool {
        var address = cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(
            deviceID, &address, 0, nil, size, &used, &running
        ) == noErr && running != 0
    }

    // MARK: - Microphone detection

    private func rebuildAudioDevices() {
        for listener in audioDeviceListeners { listener.invalidate() }
        audioDeviceListeners.removeAll()

        let defaultInput = defaultInputDevice()
        audioDeviceIDs = audioDevices().filter { deviceID in
            guard hasInputStreams(deviceID) else { return false }
            if deviceID == defaultInput { return true }
            let transport = transportType(of: deviceID)
            return transport != kAudioDeviceTransportTypeAggregate
                && transport != kAudioDeviceTransportTypeVirtual
        }

        let runningAddress = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        audioDeviceListeners = audioDeviceIDs.compactMap { deviceID in
            let listener = AudioPropertyListener(
                objectID: deviceID,
                address: runningAddress
            ) { [weak self] in
                self?.refreshMicrophoneUsage()
            }
            if listener == nil {
                AppLog.error(
                    .calls,
                    "AudioPropertyListener init returned nil for audio device \(deviceID)"
                )
            }
            return listener
        }
        refreshMicrophoneUsage()
    }

    private func refreshMicrophoneUsage() {
        rawMicInUse = audioDeviceIDs.contains(where: audioDeviceIsRunning)
        reconcileDetectedUsage()
    }

    private func audioDevices() -> [AudioDeviceID] {
        var address = audioAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            audioSystemObject, &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            audioSystemObject, &address, 0, nil, &size, &deviceIDs
        ) == noErr else {
            return []
        }
        return deviceIDs.filter { $0 != 0 }
    }

    private func defaultInputDevice() -> AudioDeviceID {
        var address = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            audioSystemObject, &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &size
        ) == noErr && size >= MemoryLayout<AudioStreamID>.size
    }

    private func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = audioAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transport
        ) == noErr else {
            return 0
        }
        return transport
    }

    private func audioDeviceIsRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &running
        ) == noErr && running != 0
    }

    // MARK: - Transition debounce

    private func reconcileDetectedUsage() {
        let rawActive = rawCameraInUse || rawMicInUse
        if rawActive, rawSignalStartedAt == nil {
            rawSignalStartedAt = Date()
        } else if !rawActive {
            rawSignalStartedAt = nil
        }

        if rawActive == isCallLikely {
            transitionTask?.cancel()
            transitionTask = nil
            pendingTarget = nil
            if rawActive {
                publishUsage(camera: rawCameraInUse, microphone: rawMicInUse)
            }
            return
        }

        guard pendingTarget != rawActive else { return }
        transitionTask?.cancel()
        pendingTarget = rawActive
        let delay: Duration = rawActive ? .seconds(3) : .seconds(5)

        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let stillActive = self.rawCameraInUse || self.rawMicInUse
            guard stillActive == rawActive else { return }

            self.pendingTarget = nil
            self.transitionTask = nil
            if rawActive {
                self.callStartedAt = self.rawSignalStartedAt ?? Date()
                AppLog.notice(
                    .calls,
                    "call started camera=\(self.rawCameraInUse) mic=\(self.rawMicInUse)"
                )
                self.publishUsage(
                    camera: self.rawCameraInUse,
                    microphone: self.rawMicInUse
                )
            } else {
                AppLog.notice(
                    .calls,
                    "call ended camera=\(self.isCameraInUse) mic=\(self.isMicInUse)"
                )
                self.callStartedAt = nil
                self.publishUsage(camera: false, microphone: false)
            }
        }
    }

    /// Set true values before false values so a camera-to-microphone hand-off never publishes
    /// a transient all-false state.
    private func publishUsage(camera: Bool, microphone: Bool) {
        if camera, !isCameraInUse { isCameraInUse = true }
        if microphone, !isMicInUse { isMicInUse = true }
        if !camera, isCameraInUse { isCameraInUse = false }
        if !microphone, isMicInUse { isMicInUse = false }
    }

    // MARK: - Addresses

    private func audioAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func cameraAddress(
        _ selector: Int
    ) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}

/// Proc-based CoreMediaIO listener with exact `(proc, clientData)` teardown.
///
/// Swift closures can be re-bridged into distinct block objects at C call boundaries, so the
/// block-based removal API cannot reliably match a stored Swift listener. The retained weak box
/// keeps callback races safe and all observable work hops to the main actor.
private final class CMIOPropertyListener {
    private final class Box {
        weak var listener: CMIOPropertyListener?

        init(_ listener: CMIOPropertyListener) {
            self.listener = listener
        }
    }

    private let objectID: CMIOObjectID
    private let address: CMIOObjectPropertyAddress
    private let onChange: @MainActor () -> Void
    private var clientData: UnsafeMutableRawPointer?

    private static let proc: CMIOObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return noErr }
        _ = Unmanaged<Box>.fromOpaque(clientData).retain()
        let bits = UInt(bitPattern: clientData)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                let box = Unmanaged<Box>.fromOpaque(pointer).takeRetainedValue()
                box.listener?.onChange()
            }
        }
        return noErr
    }

    init?(
        objectID: CMIOObjectID,
        address: CMIOObjectPropertyAddress,
        onChange: @escaping @MainActor () -> Void
    ) {
        var probe = address
        guard objectID != 0, CMIOObjectHasProperty(objectID, &probe) else { return nil }
        self.objectID = objectID
        self.address = address
        self.onChange = onChange
        self.clientData = nil

        var register = address
        let pointer = Unmanaged.passRetained(Box(self)).toOpaque()
        guard CMIOObjectAddPropertyListener(
            objectID, &register, Self.proc, pointer
        ) == noErr else {
            Unmanaged<Box>.fromOpaque(pointer).release()
            return nil
        }
        self.clientData = pointer
    }

    func invalidate() {
        guard let pointer = clientData else { return }
        clientData = nil
        var address = self.address
        CMIOObjectRemovePropertyListener(objectID, &address, Self.proc, pointer)
        Unmanaged<Box>.fromOpaque(pointer).release()
    }

    deinit {
        invalidate()
    }
}
