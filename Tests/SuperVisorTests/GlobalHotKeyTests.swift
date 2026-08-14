import Foundation
import Testing

@testable import SuperVisor

@MainActor
@Suite("Global hot key")
struct GlobalHotKeyTests {
    /// Claiming the shipping combination proves two things at once: the wrapper's register /
    /// release cycle works, and ⌘⇧⎋ is not already held by the system or another app. A failure
    /// here means the shortcut would never fire in the app either.
    @Test("The jump shortcut can be claimed and released")
    func commandShiftEscapeIsClaimable() {
        let hotKey = GlobalHotKey(combination: .commandShiftEscape) {}
        #expect(hotKey.isRegistered == false)

        #expect(hotKey.register())
        #expect(hotKey.isRegistered)

        hotKey.unregister()
        #expect(hotKey.isRegistered == false)
    }

    @Test("Registering twice is idempotent")
    func doubleRegistrationIsIdempotent() {
        let hotKey = GlobalHotKey(combination: .commandShiftEscape) {}
        #expect(hotKey.register())
        #expect(hotKey.register())
        #expect(hotKey.isRegistered)
        hotKey.unregister()
    }

    @Test("Releasing an unclaimed shortcut is inert")
    func unregisteringWithoutRegisteringIsInert() {
        let hotKey = GlobalHotKey(combination: .commandShiftEscape) {}
        hotKey.unregister()
        #expect(hotKey.isRegistered == false)
    }
}
