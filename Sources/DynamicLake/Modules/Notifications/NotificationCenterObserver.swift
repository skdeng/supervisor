import AppKit
import ApplicationServices
import Foundation

/// Observes macOS Notification Center banners through the Accessibility (AX) API and emits
/// a parsed `NotificationItem` for each newly presented banner.
///
/// ## Approach
/// macOS does not offer a public API to read other apps' notifications. The banners the OS
/// draws (iMessage, WhatsApp, Telegram, Slack, FaceTime, …) are, however, real AX windows
/// owned by the `com.apple.notificationcenterui` process. We:
///
///   1. Find that process's pid and build an application AX element with
///      `AXUIElementCreateApplication(pid)`.
///   2. Create an `AXObserver` for that pid and register for `kAXCreatedNotification` and
///      `kAXWindowCreatedNotification`, adding the observer's run-loop source to the main
///      run loop.
///   3. When a banner element is created, walk its AX subtree and read the
///      `kAXTitle` / `kAXDescription` / `kAXValue` / `kAXStaticText` attributes of the
///      contained elements to recover the title (sender), subtitle, and body text.
///
/// ## Permission
/// This requires the host app to be a **trusted Accessibility client**. We gate everything
/// on `AXIsProcessTrustedWithOptions`. If trust is missing the observer publishes an
/// `authorizationDenied` state and the module renders an inline prompt that deep-links to
/// System Settings > Privacy & Security > Accessibility. We re-check periodically so the
/// observer self-heals the moment the user grants the permission, without a relaunch.
///
/// ## Robustness
/// Notification Center's internal view hierarchy is private and changes across macOS
/// releases, so every attribute read is defensive: missing/`nil`/wrong-typed attributes are
/// tolerated and simply skipped. The observer never assumes a particular subtree shape; it
/// collects all readable static text and reconstructs the most likely title/subtitle/body.
@MainActor
final class NotificationCenterObserver {
    /// Authorization / running state surfaced to the module.
    enum State: Equatable {
        case stopped
        case authorizationDenied
        case running
        case unavailable
    }

    /// Bundle id of the Notification Center UI agent that owns banner windows.
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// Called on the main actor for each newly captured banner.
    private let onCapture: @MainActor (NotificationItem) -> Void
    /// Called on the main actor whenever the observer's `State` changes.
    private let onStateChange: @MainActor (State) -> Void

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedPID: pid_t?

    /// Periodic timer that (a) waits for Accessibility trust to be granted and (b) recovers
    /// if the Notification Center agent restarts (it relaunches on its own).
    private var watchdog: Timer?

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange(state)
        }
    }

    /// Recent dedupe signatures with their capture time, to suppress duplicate banners that
    /// the AX layer reports more than once as a banner animates in.
    private var recentSignatures: [String: Date] = [:]

    init(
        onCapture: @escaping @MainActor (NotificationItem) -> Void,
        onStateChange: @escaping @MainActor (State) -> Void
    ) {
        self.onCapture = onCapture
        self.onStateChange = onStateChange
    }

    // MARK: - Lifecycle

    /// Begin observing. Safe to call repeatedly; it is idempotent. If Accessibility trust is
    /// missing, this starts a watchdog that retries until trust is granted.
    func start(promptForPermission: Bool) {
        guard observer == nil else { return }

        if !Self.isTrusted(prompt: promptForPermission) {
            state = .authorizationDenied
            startWatchdog()
            return
        }

        attachToNotificationCenter()
        startWatchdog()
    }

    /// Stop observing and tear down all AX resources.
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        detach()
        state = .stopped
    }

    // Teardown (timer invalidation + AX source removal) happens in `stop()`, which the owning
    // module calls from `deactivate()` before releasing this observer. A nonisolated `deinit`
    // cannot touch the main-actor-isolated timer/AX state, so `stop()` is the sole cleanup path.

    // MARK: - Permission

    /// Whether the host process is a trusted Accessibility client. When `prompt` is true and
    /// trust is missing, the system shows its standard "grant access" alert once.
    static func isTrusted(prompt: Bool) -> Bool {
        // The constant `kAXTrustedCheckOptionPrompt` is an imported global `var` that the
        // strict-concurrency checker rejects as shared mutable state; its documented value is
        // the literal CFString below, which is stable across releases.
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings directly at the Accessibility privacy pane so the user can grant
    /// access in one step.
    @MainActor
    static func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so this fires on the main actor.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func tick() {
        // Recover trust if it was granted after we started in a denied state.
        if observer == nil {
            if Self.isTrusted(prompt: false) {
                attachToNotificationCenter()
            }
            return
        }

        // The Notification Center agent can relaunch under a new pid; re-attach if ours died
        // or the pid changed.
        if let observedPID, !Self.isProcessAlive(observedPID) {
            detach()
            attachToNotificationCenter()
        } else if let current = Self.notificationCenterPID(), current != observedPID {
            detach()
            attachToNotificationCenter()
        }

        pruneRecentSignatures()
    }

    // MARK: - AX attach / detach

    private func attachToNotificationCenter() {
        guard observer == nil else { return }
        guard Self.isTrusted(prompt: false) else {
            state = .authorizationDenied
            return
        }
        guard let pid = Self.notificationCenterPID() else {
            // Agent not running yet; the watchdog will retry.
            state = .unavailable
            return
        }

        let app = AXUIElementCreateApplication(pid)

        var newObserver: AXObserver?
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        let createResult = AXObserverCreate(pid, Self.axCallback, &newObserver)
        guard createResult == .success, let axObserver = newObserver else {
            state = .unavailable
            return
        }

        // Register for both element-created and window-created notifications. Banners arrive
        // as one or the other depending on the macOS release and banner style, so we observe
        // both and de-duplicate downstream.
        let notifications: [String] = [
            kAXCreatedNotification as String,
            kAXWindowCreatedNotification as String,
        ]
        for name in notifications {
            // A failure here is non-fatal — some notifications may be unsupported; we keep
            // whatever registers.
            _ = AXObserverAddNotification(axObserver, app, name as CFString, unmanagedSelf)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(axObserver),
            .commonModes
        )

        observer = axObserver
        appElement = app
        observedPID = pid
        state = .running
    }

    private func detach() {
        if let observer, let appElement {
            let notifications: [String] = [
                kAXCreatedNotification as String,
                kAXWindowCreatedNotification as String,
            ]
            for name in notifications {
                _ = AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        appElement = nil
        observedPID = nil
    }

    // MARK: - AX callback

    /// C-compatible AX callback. `refcon` carries an unretained pointer to the observer
    /// instance. Runs on the main run loop (we added the source to the main run loop).
    private static let axCallback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<NotificationCenterObserver>.fromOpaque(refcon)
            .takeUnretainedValue()
        // The AX run-loop source is installed on the main run loop, so this fires on the
        // main actor synchronously; `element` does not cross threads. Box it so the
        // non-Sendable AXUIElement can be carried into the isolated body.
        let box = UncheckedSendableBox(element)
        MainActor.assumeIsolated { observer.handleCreated(element: box.value) }
    }

    private func handleCreated(element: AXUIElement) {
        // The created element may be the banner itself or an ancestor window; in either case
        // parse its subtree for notification text.
        guard let item = parseBanner(root: element) else { return }

        // Suppress duplicates within a short window.
        let now = Date()
        if let last = recentSignatures[item.dedupeSignature],
           now.timeIntervalSince(last) < 4.0 {
            return
        }
        recentSignatures[item.dedupeSignature] = now

        let deliver = onCapture
        Task { @MainActor in deliver(item) }
    }

    // MARK: - Banner parsing

    /// Walk the AX subtree under `root` and reconstruct a `NotificationItem`.
    ///
    /// We do not rely on a fixed hierarchy. Instead we gather every readable text fragment
    /// (title/description/value/static-text) in document order, plus any app-name hint, and
    /// reconstruct the most likely title / subtitle / body. This keeps parsing resilient to
    /// the private, version-specific Notification Center view tree.
    private func parseBanner(root: AXUIElement) -> NotificationItem? {
        var texts: [String] = []
        var appNameHint: String?

        collectText(from: root, depth: 0, texts: &texts, appNameHint: &appNameHint)

        // Strip control chrome strings the AX tree exposes ("Close", "Options", time stamps
        // like "now", etc.) that are never part of the message content.
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !Self.isChrome($0) }

        guard !cleaned.isEmpty else { return nil }

        // Heuristic reconstruction:
        //   - First fragment is the title (sender / conversation).
        //   - If there are three or more fragments, the second is a subtitle (group/thread)
        //     and the remainder is the body.
        //   - With exactly two, the second is the body.
        let title = cleaned[0]
        var subtitle: String?
        var body: String?

        switch cleaned.count {
        case 1:
            break
        case 2:
            body = cleaned[1]
        default:
            subtitle = cleaned[1]
            body = cleaned[2...].joined(separator: " ")
        }

        return NotificationItem(
            title: title,
            subtitle: subtitle,
            body: body,
            appName: appNameHint
        )
    }

    /// Recursively collect text attributes from an AX element subtree. Bounded in depth to
    /// avoid pathological trees. Every read is optional/defensive.
    private func collectText(
        from element: AXUIElement,
        depth: Int,
        texts: inout [String],
        appNameHint: inout String?
    ) {
        guard depth < 12 else { return }

        // App-name hint: Notification Center tags the banner's app via the AX identifier or
        // a "subrole"/help attribute on some releases; we also accept a value that matches a
        // running app name later. Read the description as a weak hint.
        if appNameHint == nil, let identifier = Self.stringAttribute(element, "AXIdentifier") {
            // Identifiers sometimes look like "<bundleid>:<...>"; the leading component is a
            // useful app hint when it resolves to a known app, but we keep the raw text and
            // let the icon resolver decide.
            if !identifier.isEmpty, !identifier.contains(" ") {
                appNameHint = appNameHint ?? Self.appNameFromIdentifier(identifier)
            }
        }

        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = Self.stringAttribute(element, attribute as String) {
                texts.append(text)
            }
        }

        // Recurse into children.
        if let children = Self.childrenAttribute(element) {
            for child in children {
                collectText(from: child, depth: depth + 1, texts: &texts, appNameHint: &appNameHint)
            }
        }
    }

    // MARK: - AX attribute helpers (defensive)

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            let string = value as! CFString as String
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func childrenAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        )
        guard result == .success, let value else { return nil }
        if CFGetTypeID(value) == CFArrayGetTypeID() {
            return (value as? [AXUIElement])
        }
        return nil
    }

    /// Best-effort app-name extraction from an AX identifier that looks like a bundle id.
    private static func appNameFromIdentifier(_ identifier: String) -> String? {
        // Take the component before the first ":" and use the last dotted segment as a hint
        // (e.g. "com.tinyspeck.slackmacgap:..." -> "slackmacgap"). The icon resolver maps
        // common names; unknown ones simply yield no icon.
        let head = identifier.split(separator: ":").first.map(String.init) ?? identifier
        guard head.contains(".") else { return nil }
        return head.split(separator: ".").last.map(String.init)
    }

    /// Strings that are notification chrome rather than content.
    private static func isChrome(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let chrome: Set<String> = [
            "close", "options", "clear", "clear all", "show", "reply", "dismiss",
            "now", "notification", "notification center",
        ]
        if chrome.contains(lowered) { return true }
        // Relative timestamps such as "5m ago", "2h ago", "yesterday".
        if lowered.hasSuffix(" ago") { return true }
        return false
    }

    // MARK: - Process helpers

    private static func notificationCenterPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == notificationCenterBundleID
        }?.processIdentifier
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid }
    }

    private func pruneRecentSignatures() {
        let cutoff = Date().addingTimeInterval(-10)
        recentSignatures = recentSignatures.filter { $0.value > cutoff }
    }
}

/// Carries a non-Sendable value across an isolation boundary that is known to be a
/// same-thread synchronous hop (e.g. a C run-loop callback into `MainActor.assumeIsolated`).
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
