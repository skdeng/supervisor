import Foundation

/// Reads (and, where possible, writes) the keyboard backlight level via the private
/// CoreBrightness `KeyboardBrightnessClient`.
///
/// Symbols are resolved at runtime with `dlopen`/`dlsym`. `KeyboardBrightnessClient` is an
/// Objective-C class inside CoreBrightness; we reach it through the Objective-C runtime
/// (`objc_getClass` + `objc_msgSend`) rather than a bridging header. The relevant selectors
/// historically are:
///
///  - `-brightnessForKeyboard:` (keyboard id, default `1`) -> `Float`/`Double`
///  - `-setBrightness:forKeyboard:` -> set level
///
/// OS LIMITATIONS:
///  - This is a private, unsupported class; selectors and even the class name vary across
///    macOS releases and Apple Silicon vs. Intel. Every step is guarded and the controller
///    reports `isAvailable == false` if the class/selectors don't resolve, in which case it
///    is a graceful no-op (many recent Macs also expose no software-controllable keyboard
///    backlight at all, e.g. when ambient keyboard backlight is hardware-managed).
///  - There is no change notification; level is polled while active and emitted on change.
final class KeyboardBacklightController: @unchecked Sendable {
    /// Called whenever the keyboard backlight scalar (`0...1`) changes, on the main actor.
    var onChange: (@MainActor @Sendable (_ level: Float) -> Void)?

    /// Whether a usable backend was resolved (so the UI can hide keyboard backlight if not).
    private(set) var isAvailable: Bool = false

    private let queue = DispatchQueue(label: "com.supervisor.systemhud.keyboard")
    private var pollTimer: DispatchSourceTimer?
    private var lastEmitted: Float = -1

    /// The keyboard id used by KeyboardBrightnessClient (the built-in keyboard is `1`).
    private let keyboardID: UInt64 = 1

    // MARK: Objective-C runtime bindings

    private typealias GetClass = @convention(c) (UnsafePointer<CChar>) -> AnyClass?
    private typealias GetSelector = @convention(c) (UnsafePointer<CChar>) -> Selector?

    /// `+[NSObject alloc]` / `-init` then the getter/setter, all reached via objc_msgSend
    /// variants cast to the exact argument/return signature we need.
    private typealias MsgSendVoidToObj = @convention(c) (AnyObject?, Selector) -> AnyObject?
    private typealias MsgSendGetFloat = @convention(c) (AnyObject?, Selector, UInt64) -> Float
    private typealias MsgSendSetFloat = @convention(c) (AnyObject?, Selector, Float, UInt64) -> Void

    private var client: AnyObject?
    private var getSel: Selector?
    private var setSel: Selector?

    private var msgSendGet: MsgSendGetFloat?
    private var msgSendSet: MsgSendSetFloat?

    init() {
        resolve()
    }

    private func resolve() {
        // CoreBrightness hosts KeyboardBrightnessClient. Open it so the class is realized.
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW
        ) != nil else { return }

        guard let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            return
        }

        // Bind the objc_msgSend variants to precise signatures.
        guard
            let allocSym = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend")
        else { return }
        let msgSendAlloc = unsafeBitCast(allocSym, to: MsgSendVoidToObj.self)
        msgSendGet = unsafeBitCast(allocSym, to: MsgSendGetFloat.self)
        msgSendSet = unsafeBitCast(allocSym, to: MsgSendSetFloat.self)

        // Instantiate: [[KeyboardBrightnessClient alloc] init]
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("init")
        guard let allocated = msgSendAlloc(clientClass, allocSel) else { return }
        guard let instance = msgSendAlloc(allocated, initSel) as? NSObject else { return }
        client = instance

        // Resolve getter/setter selectors, accepting the known historical spellings.
        let getCandidates = ["brightnessForKeyboard:", "keyboardBrightnessForKeyboard:"]
        let setCandidates = ["setBrightness:forKeyboard:", "setKeyboardBrightness:forKeyboard:"]

        getSel = getCandidates.map { NSSelectorFromString($0) }.first { instance.responds(to: $0) }
        setSel = setCandidates.map { NSSelectorFromString($0) }.first { instance.responds(to: $0) }

        isAvailable = (getSel != nil)
    }

    // MARK: Lifecycle

    func start() {
        guard isAvailable else { return }
        queue.async { [weak self] in self?.emitIfChanged() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in self?.emitIfChanged() }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: Reads / writes

    private func read() -> Float? {
        guard let client, let getSel, let msgSendGet, isAvailable else { return nil }
        let value = msgSendGet(client, getSel, keyboardID)
        guard value.isFinite, value >= 0 else { return nil }
        return max(0, min(1, value))
    }

    /// Writes the keyboard backlight scalar (`0...1`) if a setter is available.
    func setLevel(_ value: Float) {
        let clamped = max(0, min(1, value))
        queue.async { [weak self] in
            guard let self, let client = self.client, let setSel = self.setSel,
                  let msgSendSet = self.msgSendSet else { return }
            msgSendSet(client, setSel, clamped, self.keyboardID)
            self.emitIfChanged()
        }
    }

    private func emitIfChanged() {
        guard let current = read() else { return }
        if abs(current - lastEmitted) < 0.01 { return }
        lastEmitted = current
        guard let cb = onChange else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(current) } }
    }
}
