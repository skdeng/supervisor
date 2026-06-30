import AppKit

/// Watches the global cursor position and reports when it enters or leaves an "activation
/// rect" around the notch, driving hover-to-expand and hover-to-collapse.
///
/// Uses both a global monitor (mouse moves while another app is frontmost) and a local
/// monitor (moves delivered to our own window) so detection works regardless of which app
/// owns focus. Enter fires after a short dwell; exit fires after a short grace delay. Both
/// debounce so the surface does not flicker at the activation boundary.
@MainActor
public final class HoverMonitor {
    /// Called when the cursor settles inside the activation rect.
    public var onEnter: (() -> Void)?
    /// Called when the cursor leaves the activation rect (after the grace delay).
    public var onExit: (() -> Void)?

    /// The activation rect in **global screen coordinates** (origin bottom-left). The
    /// engine updates this as geometry and state change.
    public var activationRect: CGRect = .zero

    /// Dwell before an enter is committed. Scaled by hover sensitivity.
    private var enterDwell: TimeInterval = 0.08
    /// Grace delay before an exit is committed.
    private var exitGrace: TimeInterval = 0.25

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var isInside = false
    private var pendingEnter: DispatchWorkItem?
    private var pendingExit: DispatchWorkItem?

    public init() {}

    /// Apply hover sensitivity. Hover is intentionally instant (no enter/exit delay) so the
    /// grow affordance tracks the cursor immediately; the parameter is retained for the
    /// settings slider but currently has no timing effect.
    public func setSensitivity(_ sensitivity: Double) {
        _ = sensitivity
        enterDwell = 0
        exitGrace = 0
    }

    public func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate(NSEvent.mouseLocation)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.evaluate(NSEvent.mouseLocation)
            }
            return event
        }

        // Seed the initial state from the current cursor position.
        evaluate(NSEvent.mouseLocation)
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        pendingEnter?.cancel()
        pendingExit?.cancel()
        pendingEnter = nil
        pendingExit = nil
    }

    /// Force a re-evaluation against the current cursor position, e.g. after the activation
    /// rect changes because the surface expanded or collapsed.
    public func refresh() {
        evaluate(NSEvent.mouseLocation)
    }

    private func evaluate(_ location: NSPoint) {
        let nowInside = activationRect.contains(location)
        guard nowInside != isInside else {
            // Stable: cancel any pending opposite transition.
            if nowInside { pendingExit?.cancel(); pendingExit = nil }
            else { pendingEnter?.cancel(); pendingEnter = nil }
            return
        }

        if nowInside {
            // Entering: cancel a pending exit, schedule a debounced enter.
            pendingExit?.cancel(); pendingExit = nil
            guard pendingEnter == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingEnter = nil
                guard self.activationRect.contains(NSEvent.mouseLocation) else { return }
                self.isInside = true
                self.onEnter?()
            }
            pendingEnter = work
            DispatchQueue.main.asyncAfter(deadline: .now() + enterDwell, execute: work)
        } else {
            // Leaving: cancel a pending enter, schedule a debounced exit.
            pendingEnter?.cancel(); pendingEnter = nil
            guard pendingExit == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingExit = nil
                guard !self.activationRect.contains(NSEvent.mouseLocation) else { return }
                self.isInside = false
                self.onExit?()
            }
            pendingExit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + exitGrace, execute: work)
        }
    }
}
