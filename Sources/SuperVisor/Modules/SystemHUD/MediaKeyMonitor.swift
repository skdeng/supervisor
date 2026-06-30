import AppKit

/// Observes hardware brightness / illumination / sound media keys via a global+local
/// `NSEvent` monitor on `.systemDefined` events.
///
/// macOS delivers the function-row hardware keys (brightness up/down, keyboard illumination
/// up/down, sound up/down/mute) as `NSEventType.systemDefined` events with subtype `8`
/// (NX_SUBTYPE_AUX_CONTROL_BUTTONS). The pressed key code is packed into the high bits of
/// `event.data1`, and the key state (down/up/repeat) into the low bits.
///
/// We use this purely as a *hint* to peek the HUD the instant the user taps a media key —
/// the authoritative value still comes from the CoreAudio / DisplayServices controllers.
/// This avoids a perceptible lag between key-press and HUD appearance and lets us surface
/// the correct facet (volume vs. brightness vs. keyboard backlight) immediately.
///
/// OS LIMITATION: a *global* monitor (for key presses while another app is focused) requires
/// the Accessibility (AXIsProcessTrusted) privilege. Without it, only the *local* monitor
/// fires (when SuperVisor is frontmost). We install both and degrade gracefully; the
/// controllers' value observers still catch every change regardless of focus, so the only
/// thing lost without Accessibility is the zero-latency key hint while another app is active.
@MainActor
final class MediaKeyMonitor {
    /// The facet a media key targets.
    enum Facet {
        case volume
        case brightness
        case keyboardBacklight
        case mute
    }

    /// Called on the main actor when a relevant media key is pressed down.
    var onKeyDown: ((Facet) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // NX system-defined media key codes (from IOKit/hidsystem/ev_keymap.h).
    private enum NXKey: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case illuminationUp = 21
        case illuminationDown = 22
    }

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handle(event)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined]) { event in
            handler(event)
        }
        // The local monitor must return the event to keep normal delivery intact.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.systemDefined]) { event in
            handler(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Only aux-control button events carry media keys.
        guard event.subtype.rawValue == 8 else { return }

        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0x0A // NX_KEYDOWN

        guard isKeyDown else { return }

        let facet: Facet?
        switch NXKey(rawValue: keyCode) {
        case .soundUp, .soundDown:
            facet = .volume
        case .mute:
            facet = .mute
        case .brightnessUp, .brightnessDown:
            facet = .brightness
        case .illuminationUp, .illuminationDown:
            facet = .keyboardBacklight
        case .none:
            facet = nil
        }

        if let facet {
            onKeyDown?(facet)
        }
    }
}
