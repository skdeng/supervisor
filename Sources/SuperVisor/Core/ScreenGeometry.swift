import AppKit
import Combine

/// Describes the physical (or synthesized) notch on the active screen, plus the derived
/// frames the engine uses to place the window and lay out content.
///
/// All rects are in **global AppKit screen coordinates** (origin bottom-left, y up),
/// which is what `NSWindow.setFrame` expects.
public struct NotchGeometry: Equatable, Sendable {
    /// The screen these measurements apply to.
    public var screenFrame: CGRect
    /// The rect of the physical notch cutout in global coordinates. For non-notch Macs
    /// this is a synthesized region centered at the top.
    public var notchRect: CGRect
    /// Whether the notch is real hardware (true) or synthesized (false).
    public var isHardwareNotch: Bool
    /// How far below the screen's top edge the surface sits once it has morphed into a floating
    /// pill: a quarter of the notch's height, enough to read as detached without wandering away
    /// from the screen edge it came from. Zero on a screen with a physical cutout, which never
    /// detaches — the surface *is* the hardware there.
    public var pillTopDrop: CGFloat = 0

    public var notchWidth: CGFloat { notchRect.width }
    public var notchHeight: CGFloat { notchRect.height }

    /// X center of the notch in global coordinates.
    public var centerX: CGFloat { notchRect.midX }

    /// Top edge (max y) of the screen in global coordinates.
    public var screenTop: CGFloat { screenFrame.maxY }

    public static let zero = NotchGeometry(
        screenFrame: .zero,
        notchRect: .zero,
        isHardwareNotch: false
    )
}

/// Detects the notch geometry and republishes it whenever the screen configuration
/// changes. The engine observes `geometry` and reflows the window.
@MainActor
public final class ScreenGeometryProvider: ObservableObject {
    /// Synthesized notch dimensions for non-notch Macs.
    private static let virtualNotchWidth: CGFloat = 200
    private static let virtualNotchHeight: CGFloat = 32

    @Published public private(set) var geometry: NotchGeometry = .zero

    private var observer: NSObjectProtocol?

    public init() {
        recompute()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recompute()
            }
        }
    }

    /// Recompute geometry from the current screen configuration, applying the user's notch
    /// calibration (width/offset).
    public func recompute() {
        let screen = Self.notchScreen()
        let store = SettingsStore.shared
        geometry = Self.geometry(
            for: screen,
            widthAdjust: CGFloat(store.notchWidthAdjust),
            offsetX: CGFloat(store.notchOffsetX)
        )
    }

    /// Pick the screen that has the hardware notch, falling back to the primary display.
    ///
    /// The fallback is `screens.first` — AppKit documents that as the display owning the menu
    /// bar — and NOT `NSScreen.main`, which is whichever display holds keyboard focus at the
    /// instant it is read. Geometry is recomputed on launch, on display reconfiguration, and
    /// on calibration changes, so keying off `main` lets the focused window at those moments
    /// decide where the surface lives: it lands on a different display depending on what the
    /// user happened to be looking at when a monitor was plugged in.
    static func notchScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Compute notch geometry for a given screen, applying a width/offset calibration.
    ///
    /// `widthAdjust` is added to the raw notch width (negative shrinks); `offsetX` shifts it
    /// horizontally. macOS reports the *menu-bar gap* as the notch, which is wider than the
    /// visible cutout, so the calibration lets the rendered notch be matched to the hardware.
    static func geometry(for screen: NSScreen?, widthAdjust: CGFloat = 0, offsetX: CGFloat = 0) -> NotchGeometry {
        guard let screen else { return .zero }
        let frame = screen.frame

        // A hardware notch reports a positive top safe-area inset. The notch height is the
        // inset; its width is the gap between the two auxiliary top areas (the usable
        // menu-bar strips to the left and right of the cutout).
        let topInset = screen.safeAreaInsets.top
        let isHardware = topInset > 0

        let rawRect: CGRect
        if isHardware,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            // Place the notch EXACTLY between the two usable menu-bar areas the OS reports —
            // its true position — instead of assuming it is centered on the screen.
            rawRect = CGRect(
                x: left.maxX,
                y: frame.maxY - topInset,
                width: right.minX - left.maxX,
                height: topInset
            )
        } else if isHardware {
            // Hardware notch but no auxiliary areas: assume a typical centered notch.
            let width: CGFloat = 200
            rawRect = CGRect(x: frame.midX - width / 2, y: frame.maxY - topInset, width: width, height: topInset)
        } else {
            // Non-notch Mac: synthesize a sensible notch centered at the top.
            rawRect = CGRect(
                x: frame.midX - virtualNotchWidth / 2,
                y: frame.maxY - virtualNotchHeight,
                width: virtualNotchWidth,
                height: virtualNotchHeight
            )
        }

        // Apply the calibration: resize symmetrically about the (offset) center.
        let adjustedWidth = max(40, rawRect.width + widthAdjust)
        let center = rawRect.midX + offsetX
        let notchRect = CGRect(
            x: center - adjustedWidth / 2,
            y: rawRect.minY,
            width: adjustedWidth,
            height: rawRect.height
        )

        return NotchGeometry(
            screenFrame: frame,
            notchRect: notchRect,
            isHardwareNotch: isHardware,
            pillTopDrop: isHardware ? 0 : notchRect.height / 4
        )
    }
}
