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

    // MARK: Spacing

    /// Horizontal inset between the notch cutout and compact content.
    public static let compactSidePadding: CGFloat = 8
    /// Padding inside the expanded panel.
    public static let panelPadding: CGFloat = 16
    /// Vertical spacing between stacked module sections in the expanded panel.
    public static let sectionSpacing: CGFloat = 12

    // MARK: Colors

    /// The black used for the pill body so it reads as part of the hardware notch.
    public static let notchBlack = Color.black
    /// Primary foreground tint for content rendered on the dark surface.
    public static let primaryForeground = Color.white
    /// Secondary, dimmer foreground tint.
    public static let secondaryForeground = Color.white.opacity(0.6)
    /// Hairline separator color.
    public static let separator = Color.white.opacity(0.12)

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

    /// Applies the expanded-panel chrome (Liquid Glass + corners + shadow).
    func panelChrome() -> some View {
        modifier(PanelChrome())
    }
}
