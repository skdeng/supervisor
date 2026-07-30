import SwiftUI

/// Design tokens and Liquid Glass material wrappers shared by all chrome and modules.
///
/// The pill that hugs the physical notch is rendered as opaque black so it blends with
/// the hardware cutout. The expanded panel and free-floating surfaces adopt the native
/// macOS 26 Liquid Glass material, gracefully degrading to `.ultraThinMaterial` when the
/// API is unavailable at runtime.
public enum NotchTheme {
    // MARK: Corner radii

    /// Corner radius of the bare notch / idle pill body.
    public static let pillCornerRadius: CGFloat = 14
    /// Corner radius of the expanded panel.
    public static let panelCornerRadius: CGFloat = 26
    /// Corner radius used for inner module surfaces inside the expanded panel.
    public static let surfaceCornerRadius: CGFloat = 16

    // MARK: Hover growth

    /// How much the surface swells while hovered, before a click opens the sheet.
    ///
    /// A hardware notch only nudges: it is welded to the physical cutout, and growing it far
    /// would peel the black surface off the bezel it is pretending to be. A pill that has
    /// already detached has no such obligation, so it can swell into a real target. The engine
    /// sizes its hit-test and hover rects from the same numbers.
    public static let notchHoverScale: CGFloat = 1.06
    public static let pillHoverScale: CGFloat = 1.2
    /// Horizontal hover swell, per side. Width growth is additive where the height swell is
    /// proportional: content rows hold their resting position under the swell, so scaling the
    /// width would turn the entire growth into empty margin on a wide pill.
    public static let hoverWidthPad: CGFloat = 10

    // MARK: Spacing

    /// Horizontal inset between the notch cutout and compact content.
    public static let compactSidePadding: CGFloat = 8
    /// Standard height of a compact contribution (album-art thumbnail, equalizer). The pill's
    /// horizontal edge padding is derived from it so the side margins match the vertical margin
    /// around standard-height content; the derivation lives in `NotchRootView`.
    public static let compactContentHeight: CGFloat = 18
    /// Padding inside the expanded panel.
    public static let panelPadding: CGFloat = 16
    /// Vertical spacing between stacked module sections in the expanded panel. Sections carry
    /// no card chrome of their own, so this gap alone is what separates them visually.
    public static let sectionSpacing: CGFloat = 20
    /// Width of the leading marker column in sheet rows (status dot, session icon) and the gap
    /// between it and the row's text. Markers of different sizes center in the same column, so
    /// adjacent sections' markers and text columns sit on one shared axis.
    public static let rowMarkerWidth: CGFloat = 18
    public static let rowMarkerGap: CGFloat = 8

    // MARK: Colors

    /// The black used for the pill body so it reads as part of the hardware notch.
    public static let notchBlack = Color.black

    /// Alpha for a fill that exists purely to be clicked on, over a material that draws no body
    /// of its own. `NSHostingView` reports a hit only where SwiftUI drew something, so a truly
    /// clear fill would let clicks fall through the window. At this alpha the fill contributes
    /// less than one unit of an 8-bit channel and is invisible.
    public static let hitTestableAlpha: Double = 0.001
    /// Primary foreground tint for content rendered on the dark surface.
    public static let primaryForeground = Color.white
    /// Secondary, dimmer foreground tint.
    public static let secondaryForeground = Color.white.opacity(0.6)
    /// Hairline separator color.
    public static let separator = Color.white.opacity(0.12)

    // MARK: Brand

    public static let brandPink = Color(red: 1.0, green: 0.29, blue: 0.62)
    public static let brandCyan = Color(red: 0.16, green: 0.85, blue: 0.96)
    public static let brandGradient = LinearGradient(
        colors: [brandPink, brandCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    public static let brandColor = Color(red: 0.62, green: 0.5, blue: 0.9)

    // MARK: Shadows

    public static let panelShadowColor = Color.black.opacity(0.45)
    public static let panelShadowRadius: CGFloat = 22
    public static let panelShadowY: CGFloat = 10
}

/// View modifier that applies the app's Liquid Glass surface treatment: the macOS 26
/// `glassEffect` material clipped to a rounded rectangle, with a graceful fallback to
/// `.ultraThinMaterial`.
public struct LiquidGlassSurface: ViewModifier {
    public var cornerRadius: CGFloat
    public var tint: Color?
    public var interactive: Bool

    public init(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            var glass = Glass.regular
            if let tint { glass = glass.tint(tint) }
            if interactive { glass = glass.interactive() }
            return AnyView(content.glassEffect(glass, in: shape))
        } else {
            return AnyView(
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(NotchTheme.separator, lineWidth: 0.5))
            )
        }
    }
}

/// View modifier that fills an arbitrary shape with Liquid Glass.
///
/// `LiquidGlassSurface` only ever clips to a rounded rectangle. The morphing notch surface is
/// neither a rectangle nor a fixed shape, so it needs the material poured into whatever
/// silhouette it currently holds.
///
/// The `clear` variant refracts what is behind it without frosting it; the regular variant
/// frosts. Both degrade to `.ultraThinMaterial` where `glassEffect` is unavailable.
public struct LiquidGlassShape<S: Shape>: ViewModifier {
    public var shape: S
    public var clear: Bool

    public init(shape: S, clear: Bool = false) {
        self.shape = shape
        self.clear = clear
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(content.glassEffect(clear ? Glass.clear : Glass.regular, in: shape))
        } else {
            return AnyView(content.background(.ultraThinMaterial, in: shape))
        }
    }
}

/// View modifier for the expanded panel chrome: Liquid Glass material plus the panel's
/// rounded corners and drop shadow.
public struct PanelChrome: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .modifier(LiquidGlassSurface(cornerRadius: NotchTheme.panelCornerRadius))
            .shadow(
                color: NotchTheme.panelShadowColor,
                radius: NotchTheme.panelShadowRadius,
                x: 0,
                y: NotchTheme.panelShadowY
            )
    }
}

public extension View {
    /// Applies the Liquid Glass surface treatment with the given corner radius.
    func liquidGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Fills the given shape with Liquid Glass, clear or frosted.
    func liquidGlass<S: Shape>(in shape: S, clear: Bool = false) -> some View {
        modifier(LiquidGlassShape(shape: shape, clear: clear))
    }

    /// Applies the expanded-panel chrome (Liquid Glass + corners + shadow).
    func panelChrome() -> some View {
        modifier(PanelChrome())
    }
}

private struct NotchTooltipModifier: ViewModifier {
    let text: String

    @State private var isPresented = false
    @State private var revealTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isPresented {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.85))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(NotchTheme.separator, lineWidth: 0.5)
                                }
                        }
                        .fixedSize()
                        .offset(y: -30)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onHover { hovering in
                revealTask?.cancel()
                revealTask = nil
                if hovering {
                    revealTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        isPresented = true
                    }
                } else {
                    isPresented = false
                }
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
                isPresented = false
            }
            .animation(.snappy(duration: 0.12), value: isPresented)
    }
}

extension View {
    func notchTooltip(_ text: String) -> some View {
        modifier(NotchTooltipModifier(text: text))
    }
}
