import CoreAudio
import Foundation

/// A CoreAudio property listener registered through the **proc-based** API
/// (`AudioObjectAddPropertyListener`), not the block-based one.
///
/// `AudioObjectRemovePropertyListenerBlock` matches registrations by block identity, but Swift
/// re-materializes a distinct block object each time a stored closure crosses the C boundary, so
/// a block-based removal never matches and leaks the registration on every call (verified: the
/// listener keeps firing after removal). A `(proc, clientData)` pair matches exactly on removal,
/// so registrations stay balanced.
///
/// The proc fires on an internal HAL thread; this hops to the main actor before invoking
/// `onChange`. `clientData` is a retained box holding a weak back-reference, so a callback that
/// races teardown safely no-ops instead of dereferencing freed memory.
final class AudioPropertyListener {
    /// Boxed weak back-reference handed to CoreAudio as `clientData`. Its `listener` is only ever
    /// read on the main actor (inside the dispatched block), so the cross-thread hand-off is
    /// limited to the opaque pointer itself.
    private final class Box {
        weak var listener: AudioPropertyListener?
        init(_ listener: AudioPropertyListener) { self.listener = listener }
    }

    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let onChange: @MainActor () -> Void
    private var clientData: UnsafeMutableRawPointer?

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        // Retain across the hop so an in-flight callback can't dereference a freed box if the
        // listener is invalidated concurrently; balanced by `takeRetainedValue()` on the main actor.
        _ = Unmanaged<Box>.fromOpaque(clientData).retain()
        // Carry the box across to the main actor as its Sendable pointer bits (the raw pointer
        // itself is task-isolated to this C callback and can't be captured directly).
        let bits = UInt(bitPattern: clientData)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let ptr = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                let box = Unmanaged<Box>.fromOpaque(ptr).takeRetainedValue()
                box.listener?.onChange()
            }
        }
        return noErr
    }

    /// Register a listener on `objectID` for `address`. Returns `nil` if the object lacks the
    /// property or registration fails. `onChange` is invoked on the main actor.
    init?(objectID: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping @MainActor () -> Void) {
        var probe = address
        guard objectID != 0, AudioObjectHasProperty(objectID, &probe) else { return nil }
        self.objectID = objectID
        self.address = address
        self.onChange = onChange
        self.clientData = nil

        var register = address
        let ptr = Unmanaged.passRetained(Box(self)).toOpaque()
        guard AudioObjectAddPropertyListener(objectID, &register, Self.proc, ptr) == noErr else {
            Unmanaged<Box>.fromOpaque(ptr).release()
            return nil
        }
        self.clientData = ptr
    }

    /// Unregister and release the client-data box. Idempotent.
    func invalidate() {
        guard let ptr = clientData else { return }
        clientData = nil
        var address = self.address
        AudioObjectRemovePropertyListener(objectID, &address, Self.proc, ptr)
        Unmanaged<Box>.fromOpaque(ptr).release()
    }

    deinit { invalidate() }
}
