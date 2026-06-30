import CoreGraphics
import Foundation

/// Reads and writes the built-in display's backlight brightness via the private
/// DisplayServices framework, with a CoreDisplay fallback.
///
/// Symbols are resolved at runtime with `dlopen`/`dlsym` (per the project's private-framework
/// rule — no bridging header / module map). Two backends are tried in order:
///
///  1. **DisplayServices** — `DisplayServicesGetBrightness(CGDirectDisplayID, UnsafeMutablePointer<Float>)`
///     and `DisplayServicesSetBrightness(CGDirectDisplayID, Float)`. This is the API the OS
///     itself uses; it persists the value and updates the menu-bar/HUD state.
///  2. **CoreDisplay** — `CoreDisplay_Display_GetUserBrightness` / `..._SetUserBrightness`
///     (taking a `Double`). Used when DisplayServices symbols are unavailable.
///
/// OS LIMITATIONS:
///  - Brightness can only be set on displays that expose a backlight (built-in panels and
///    some Apple external displays). External displays controlled over DDC are not handled.
///  - There is no public/stable *notification* for brightness changes; callers poll. We use
///    a lightweight timer poll and only emit on change.
///  - Both frameworks are private and unsupported; every symbol is guarded and the controller
///    degrades to a no-op if neither backend resolves.
final class BrightnessController: @unchecked Sendable {
    /// Called whenever the brightness scalar (`0...1`) changes, on the main actor.
    var onChange: (@MainActor @Sendable (_ brightness: Float) -> Void)?

    /// Whether a usable backend was resolved (so the UI can hide brightness if not).
    private(set) var isAvailable: Bool = false

    private let queue = DispatchQueue(label: "com.supervisor.systemhud.brightness")
    private var pollTimer: DispatchSourceTimer?
    private var lastEmitted: Float = -1

    // MARK: dlsym'd function bindings

    private typealias DSGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CDGetUserBrightness = @convention(c) (CGDirectDisplayID) -> Double
    private typealias CDSetUserBrightness = @convention(c) (CGDirectDisplayID, Double) -> Int32

    private var dsGet: DSGetBrightness?
    private var dsSet: DSSetBrightness?
    private var cdGet: CDGetUserBrightness?
    private var cdSet: CDSetUserBrightness?

    // MARK: Lifecycle

    init() {
        resolveSymbols()
    }

    private func resolveSymbols() {
        if let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW
        ) {
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                dsGet = unsafeBitCast(sym, to: DSGetBrightness.self)
            }
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                dsSet = unsafeBitCast(sym, to: DSSetBrightness.self)
            }
        }

        if let handle = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW
        ) {
            if let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") {
                cdGet = unsafeBitCast(sym, to: CDGetUserBrightness.self)
            }
            if let sym = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") {
                cdSet = unsafeBitCast(sym, to: CDSetUserBrightness.self)
            }
        }

        isAvailable = (dsGet != nil) || (cdGet != nil)
    }

    func start() {
        guard isAvailable else { return }
        queue.async { [weak self] in self?.emitIfChanged() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.emitIfChanged() }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: Reads / writes

    /// The display whose backlight we control: the main display.
    private var targetDisplay: CGDirectDisplayID { CGMainDisplayID() }

    /// Reads the current brightness scalar in `0...1`, or `nil` if unreadable.
    private func read() -> Float? {
        let display = targetDisplay
        if let dsGet {
            var value: Float = 0
            if dsGet(display, &value) == 0 {
                return max(0, min(1, value))
            }
        }
        if let cdGet {
            let value = cdGet(display)
            if value.isFinite, value >= 0 {
                return Float(max(0, min(1, value)))
            }
        }
        return nil
    }

    /// Writes the brightness scalar (`0...1`). DisplayServices is preferred because it
    /// persists and drives the OS HUD; CoreDisplay is the fallback.
    func setBrightness(_ value: Float) {
        let clamped = max(0, min(1, value))
        queue.async { [weak self] in
            guard let self else { return }
            let display = self.targetDisplay
            if let dsSet, dsSet(display, clamped) == 0 {
                self.emitIfChanged()
                return
            }
            if let cdSet { _ = cdSet(display, Double(clamped)) }
            self.emitIfChanged()
        }
    }

    private func emitIfChanged() {
        guard let current = read() else { return }
        // Quantize so floating-point jitter doesn't spam updates.
        if abs(current - lastEmitted) < 0.004 { return }
        lastEmitted = current
        guard let cb = onChange else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(current) } }
    }
}
