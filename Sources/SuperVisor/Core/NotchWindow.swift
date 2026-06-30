import AppKit
import SwiftUI

/// A borderless, non-activating panel pinned over the physical notch.
///
/// The panel sits above the status bar, shows on all spaces, floats over fullscreen apps, and
/// is excluded from Mission Control and the window cycle. Its background is fully transparent.
/// Rather than toggling `ignoresMouseEvents`, it routes events through a content container
/// that hit-tests against an "interactive rect" (the notch / sheet bounds) — clicks and file
/// drags land only there, everything else passes through to the apps beneath. The container is
/// also a file-drag destination so a file dragged onto the notch opens the sheet.
public final class NotchWindow: NSPanel {
    /// Interactive region (clicks + drags) in the content view's bounds coordinates
    /// (bottom-left origin). Outside it, events pass through.
    public var interactiveRect: CGRect = .zero {
        didSet { container?.interactiveRect = interactiveRect }
    }
    /// A file drag entered the notch region.
    public var onFileDragEntered: (() -> Void)? {
        didSet { container?.onFileDragEntered = onFileDragEntered }
    }
    /// A file drag left the notch / sheet region without dropping.
    public var onFileDragExited: (() -> Void)? {
        didSet { container?.onFileDragExited = onFileDragExited }
    }
    /// Files were dropped onto the notch / sheet.
    public var onFilesDropped: (([URL]) -> Void)? {
        didSet { container?.onFilesDropped = onFilesDropped }
    }

    private weak var container: NotchContentContainer?

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        level = .init(Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isRestorable = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Install a SwiftUI root view inside the hit-testing / drag-destination container.
    public func setRootView<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }

        let container = NotchContentContainer()
        container.interactiveRect = interactiveRect
        container.onFileDragEntered = onFileDragEntered
        container.onFileDragExited = onFileDragExited
        container.onFilesDropped = onFilesDropped
        hosting.frame = container.bounds
        container.addSubview(hosting)

        contentView = container
        self.container = container
    }
}

/// Hosts the SwiftUI view, passes events through outside the interactive rect, and accepts
/// file drags onto the notch.
final class NotchContentContainer: NSView {
    var interactiveRect: CGRect = .zero
    var onFileDragEntered: (() -> Void)?
    var onFileDragExited: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    /// Whether we have signaled "the drag is over the notch" to the engine. Tracked so
    /// enter/exit fire on the notch-rect crossing — not the coarse view-level enter/exit — and
    /// exactly once per transition, so the sheet can't get stuck open or collapse spuriously
    /// while a file is still being dragged toward the notch.
    private var isTargeting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only the interactive region (notch / sheet) receives clicks; the transparent remainder
    /// of the canvas passes events through to the windows beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: File-drag destination

    private func isOverNotch(_ sender: any NSDraggingInfo) -> Bool {
        interactiveRect.contains(convert(sender.draggingLocation, from: nil))
    }

    private func hasFiles(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// Drive the engine's drag-targeting state on the over-notch transition, firing exactly
    /// once each way.
    private func setTargeting(_ active: Bool) {
        guard active != isTargeting else { return }
        isTargeting = active
        if active { onFileDragEntered?() } else { onFileDragExited?() }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let over = hasFiles(sender) && isOverNotch(sender)
        setTargeting(over)
        return over ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let over = hasFiles(sender) && isOverNotch(sender)
        setTargeting(over)
        return over ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setTargeting(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // A successful drop does NOT route through draggingExited, so resolve targeting here.
        let urls = fileURLs(sender)
        guard !urls.isEmpty else {
            // Drop yielded no usable file URLs: clear the targeting state so the sheet isn't
            // left jammed on the drop-only view with no further drag event to release it.
            setTargeting(false)
            return false
        }
        // Stage first (keeps the sheet open showing the staged files), then clear the internal
        // flag WITHOUT firing the exit/collapse path.
        onFilesDropped?(urls)
        isTargeting = false
        return true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // Final backstop: guarantee the targeting state is resolved however the drag concluded.
        setTargeting(false)
    }
}
