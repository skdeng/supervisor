import CoreAudio
import Foundation

/// Reports whether any process other than this one is running audio output right now.
///
/// The system-audio tap captures the pre-mix output of every app, so a now-playing session whose
/// sound never reaches this Mac (a player casting to a speaker, a source playing at zero volume)
/// hands the tap silence for as long as its "playing" state lasts. This answers the question the
/// tap cannot: is anyone here producing sound at all? CoreAudio exposes one object per audio
/// client with `kAudioProcessPropertyIsRunningOutput`; this process is excluded because its own
/// tap aggregate counts as running output while the tap is up.
///
/// Re-evaluation is event-driven, with no timer: a listener on the process-object list follows
/// clients coming and going, and a listener per process object follows that client starting or
/// stopping output. `isAnyProcessRunningOutput` is `nil` while the answer cannot be trusted —
/// before `start()`, when the process list cannot be read or comes back empty, or when the
/// list listener failed to register so a stale reading could never be refreshed — and a caller
/// falls back to a weaker signal rather than treat "unknown" as silence.
@MainActor
final class LocalAudioOutputMonitor {
    private(set) var isAnyProcessRunningOutput: Bool?
    /// Invoked on the main actor whenever `isAnyProcessRunningOutput` changes value after
    /// `start()` has seeded it.
    var onChange: (@MainActor () -> Void)?

    private let ownProcessID = ProcessInfo.processInfo.processIdentifier
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var listListener: AudioPropertyListener?
    private var processListeners: [AudioObjectID: AudioPropertyListener] = [:]
    private var started = false

    /// Registers the listeners and seeds `isAnyProcessRunningOutput` synchronously, without
    /// invoking `onChange`, so the caller can read the value as soon as this returns.
    func start() {
        guard !started else { return }
        started = true

        listListener = AudioPropertyListener(
            objectID: systemObject,
            address: Self.address(kAudioHardwarePropertyProcessObjectList),
            onChange: { [weak self] in self?.evaluate(notify: true) }
        )
        if listListener == nil {
            AppLog.error(.media, "LocalAudioOutputMonitor: process-list listener registration failed")
        }
        evaluate(notify: false)
    }

    func stop() {
        guard started else { return }
        started = false
        listListener?.invalidate()
        listListener = nil
        for listener in processListeners.values { listener.invalidate() }
        processListeners.removeAll()
        isAnyProcessRunningOutput = nil
    }

    private func evaluate(notify: Bool) {
        let value: Bool?
        if listListener == nil {
            value = nil
        } else if let objects = Self.processObjects(), !objects.isEmpty {
            reconcileProcessListeners(with: objects)
            value = objects.contains { object in
                guard let pid = Self.processID(of: object), pid != ownProcessID else { return false }
                return Self.isRunningOutput(object)
            }
        } else {
            value = nil
        }
        guard value != isAnyProcessRunningOutput else { return }
        isAnyProcessRunningOutput = value
        if notify { onChange?() }
    }

    private func reconcileProcessListeners(with objects: [AudioObjectID]) {
        let live = Set(objects)
        for (object, listener) in processListeners where !live.contains(object) {
            listener.invalidate()
            processListeners.removeValue(forKey: object)
        }
        for object in live where processListeners[object] == nil {
            processListeners[object] = AudioPropertyListener(
                objectID: object,
                address: Self.address(kAudioProcessPropertyIsRunningOutput),
                onChange: { [weak self] in self?.evaluate(notify: true) }
            )
        }
    }

    // MARK: - CoreAudio queries

    nonisolated private static func processObjects() -> [AudioObjectID]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = objects.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return nil }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    nonisolated private static func processID(of object: AudioObjectID) -> pid_t? {
        var address = Self.address(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr,
              pid > 0 else { return nil }
        return pid
    }

    nonisolated private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
