import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut.
///
/// Carbon's hot-key API is what a menu-bar agent needs here: it requires no Accessibility grant,
/// fires while another app owns the keyboard, and — unlike `NSEvent.addGlobalMonitorForEvents`,
/// which can only observe — it *consumes* the keystroke, so the shortcut does not also reach the
/// frontmost app. `NotchWindow` never becomes key, so no responder-chain mechanism can see a
/// keystroke at all.
///
/// Register only while the shortcut can actually do something. A combination held permanently is
/// one the rest of the system can never use, so callers arm it on the state that makes it
/// meaningful and release it the moment that state ends.
@MainActor
final class GlobalHotKey {
    struct Combination: Equatable {
        /// A virtual key code (`kVK_*`).
        let keyCode: UInt32
        /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
        let modifiers: UInt32

        static let commandShiftEscape = Combination(
            keyCode: UInt32(kVK_Escape),
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    /// Live shortcuts by hot-key id. Carbon dispatches every hot key to one process-wide handler,
    /// which carries only the id, so the id is the only way back to the action.
    private static var actionsByID: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var dispatcher: EventHandlerRef?

    private let combination: Combination
    private let action: () -> Void
    private var id: UInt32?
    private var reference: EventHotKeyRef?
    /// A conflicting holder may quit, so registration is retried on every arming — but the
    /// failure is reported once, or a permanent conflict would log on every queue change.
    private var hasReportedFailure = false

    var isRegistered: Bool { reference != nil }

    init(combination: Combination, action: @escaping () -> Void) {
        self.combination = combination
        self.action = action
    }

    isolated deinit {
        unregister()
    }

    /// Claim the combination. Returns false when the system or another app already holds it —
    /// callers surface that rather than leaving a shortcut that silently never fires.
    @discardableResult
    func register() -> Bool {
        guard !isRegistered else { return true }
        Self.installDispatcherIfNeeded()

        let id = Self.nextID
        Self.nextID &+= 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            if !hasReportedFailure {
                hasReportedFailure = true
                AppLog.error(.engine, "global hot key registration failed with status \(status)")
            }
            return false
        }

        self.id = id
        self.reference = reference
        hasReportedFailure = false
        Self.actionsByID[id] = action
        return true
    }

    /// Release the combination back to the rest of the system.
    func unregister() {
        guard let reference else { return }
        UnregisterEventHotKey(reference)
        self.reference = nil
        if let id {
            Self.actionsByID[id] = nil
            self.id = nil
        }
    }

    /// Arm or release in one call, so callers can hand it a condition instead of tracking state.
    @discardableResult
    func setRegistered(_ registered: Bool) -> Bool {
        if registered { return register() }
        unregister()
        return true
    }

    fileprivate static func fire(_ id: UInt32) {
        actionsByID[id]?()
    }

    /// `'SVhk'` — the four-char signature Carbon stamps on this process's hot keys.
    private static let signature: OSType = 0x5356_686B

    private static func installDispatcherIfNeeded() {
        guard dispatcher == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyDispatcher,
            1,
            &spec,
            nil,
            &handler
        )
        guard status == noErr else {
            AppLog.error(.engine, "global hot key dispatcher install failed with status \(status)")
            return
        }
        dispatcher = handler
    }
}

/// Carbon's C callback. It cannot be actor-isolated, so it reads the id and hands the work to the
/// main actor.
private func hotKeyDispatcher(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    DispatchQueue.main.async { GlobalHotKey.fire(id) }
    return noErr
}
