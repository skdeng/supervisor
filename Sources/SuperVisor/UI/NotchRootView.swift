import SwiftUI

/// The SwiftUI root hosted by `NotchWindow`.
///
/// A single surface morphs from the notch into the sheet: while collapsed it is a black pill
/// hugging the hardware notch with compact live-activity content flanking the cutout; on
/// expand it grows — width and height spring outward — and its fill crossfades from black to
/// Liquid Glass, so the open reads as the notch itself expanding into the sheet rather than a
/// separate panel dropping below a static bar. A solid black cap always covers the physical
/// notch so the hardware cutout blends. The sheet is centered on the notch when open.
///
/// The window itself is a fixed-size transparent canvas; all motion happens here in SwiftUI.
struct NotchRootView: View {
    @EnvironmentObject private var engine: NotchEngine
    @ObservedObject private var settings = SettingsStore.shared
    /// Whether the system-audio tap is live (gates the beat aura) and the artwork accent color.
    @ObservedObject private var spectrum = SpectrumCenter.shared

    /// Measured natural widths of each side's compact content; drive the collapsed width and
    /// the cutout-centering offset.
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    /// Debug: render the whole surface bright red so its exact bounds are visible.
    private var debugTint: Bool { settings.debugTintEnabled }
    private var surfaceColor: Color { debugTint ? .red : NotchTheme.notchBlack }

    private var geo: NotchGeometry { engine.geometry }
    private var notchW: CGFloat { max(geo.notchWidth, 80) }
    private var notchH: CGFloat { max(geo.notchHeight, 32) }
    private var isExpanded: Bool { engine.state == .expanded }

    private var panelW: CGFloat { engine.expandedPanelWidth }
    /// Measured sheet content height — the surface grows to exactly fit the panel (no scroll).
    private var panelH: CGFloat { engine.expandedSheetHeight }

    /// Width each side of the pill reserves: the wider side's measured content width. Both
    /// sides always match, so the pill is symmetric around the cutout and never lopsided —
    /// the shorter side simply carries black slack at its outer edge.
    private var sideWidth: CGFloat { max(leadingWidth, trailingWidth) }
    /// Collapsed width: the notch plus the (equal) flanking sides.
    private var compactWidth: CGFloat { notchW + 2 * sideWidth }
    /// The morphing surface's animated size. Pill and sheet are both centered on the notch.
    private var shapeWidth: CGFloat { isExpanded ? panelW : compactWidth }
    private var shapeHeight: CGFloat { isExpanded ? notchH + panelH : notchH }
    /// Tight like a pill when collapsed, rounder as the sheet opens.
    private var radius: CGFloat { isExpanded ? NotchTheme.panelCornerRadius : NotchTheme.pillCornerRadius }

    /// Subtle grow affordance while hovering (before a click opens the sheet). Anchored at the
    /// top edge so it grows down and outward, never above the screen's top.
    private var hoverScale: CGFloat { (engine.isHovered && !isExpanded) ? 1.06 : 1.0 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Beat aura: a blurred, artwork-tinted echo of the surface that swells with the
                // music's bass. Behind the surface and unclipped, so the glow spills past the
                // silhouette; mirrors the surface's size, hover scale, and centering offset so
                // it always hugs the same shape. Exists only while the audio tap captures.
                if settings.beatAuraEnabled && spectrum.isCapturing {
                    BeatAuraView(cornerRadius: radius, accent: spectrum.accent)
                        .frame(width: shapeWidth, height: shapeHeight)
                        .scaleEffect(hoverScale, anchor: .top)
                        .allowsHitTesting(false)
                }

                // ONE surface: the notch itself grows and becomes the sheet — not a separate
                // panel dropping below a static bar. It always renders: with no compact content
                // it rests as a bare black pill exactly over the hardware notch, so the notch is
                // always present — and visibly marks the notch region on displays without a
                // physical cutout.
                morphingSurface

                // Camera cap: solid black over the physical notch so the hardware cutout blends.
                // Pinned to the notch center (never offset). Purely visual — it must not swallow
                // clicks, so taps on the notch area reach the surface's tap gesture below.
                NotchShape(cornerRadius: NotchTheme.pillCornerRadius)
                    .fill(surfaceColor)
                    .frame(width: notchW, height: notchH)
                    .allowsHitTesting(false)
            }
            // Springy when opening; critically damped (no overshoot) when closing, so the
            // notch never bounces smaller than the physical notch on the way back.
            .animation(
                isExpanded
                    ? .spring(response: 0.42, dampingFraction: 0.68)
                    : .spring(response: 0.34, dampingFraction: 1.0),
                value: isExpanded
            )
            // Non-springy: the hover grow eases in and, on hover-out, recovers to exactly the
            // original size with no overshoot — a spring here would dip below the resting size
            // and momentarily shrink the surface inside the physical notch.
            .animation(.easeOut(duration: 0.18), value: engine.isHovered)
            // Smoothly resize the open sheet when its content (and thus measured height)
            // changes — e.g. a section appears/disappears or a file drag swaps the contents.
            .animation(.spring(response: 0.34, dampingFraction: 0.9), value: engine.expandedSheetHeight)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The single shape that morphs from the notch (black pill) into the Liquid Glass sheet.
    private var morphingSurface: some View {
        ZStack(alignment: .top) {
            // One deep-black surface in every state: the notch and the sheet it grows into are
            // the same solid black, so the open reads as the notch simply expanding.
            NotchShape(cornerRadius: radius)
                .fill(surfaceColor)

            // Compact content flanks the notch while collapsed; fades out as it expands.
            CompactPillView(
                notchWidth: notchW,
                notchHeight: notchH,
                leadingWidth: $leadingWidth,
                trailingWidth: $trailingWidth
            )
            .frame(height: notchH)
            .opacity(isExpanded ? 0 : 1)

            // The sheet's content grows + fades with the surface (it inherits the body spring,
            // and scales from the notch at the top), so it expands out of the notch rather than
            // sliding in from the side. Built only while expanded or hovering (a hover always
            // precedes the click that opens it, and a file-drag opens it directly): this keeps
            // the heavy section views — and MediaScrubberView's 0.5s timer — out of the view
            // tree while the notch is idle/collapsed, so nothing runs in the background while
            // music plays. The off-screen build during hover still measures the sheet height for
            // a correct open animation.
            if isExpanded || engine.isHovered {
                ExpandedPanelView(width: panelW)
                    .padding(.top, notchH)
                    .scaleEffect(isExpanded ? 1 : 0.88, anchor: .top)
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    .transition(.identity)
            }
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .clipShape(NotchShape(cornerRadius: radius))
        .contentShape(NotchShape(cornerRadius: radius))
        .scaleEffect(hoverScale, anchor: .top)
        .shadow(color: .black.opacity(isExpanded ? 0.45 : 0), radius: 22, y: 12)
        // Click the notch to open/close the sheet (hover only previews the grow).
        .onTapGesture { if !isExpanded { engine.toggleSheet() } }
    }

}

/// The classic MacBook notch silhouette: the top edge spans the full width and flares into
/// the body through small CONCAVE fillets at the top corners (so it blends naturally into the
/// menu bar), while the bottom corners are CONVEX rounded.
struct NotchShape: Shape {
    /// Bottom corner radius (convex). Animatable so it can round out as the sheet opens.
    var cornerRadius: CGFloat
    /// Top corner radius (concave flare where the notch meets the screen's top edge).
    var topRadius: CGFloat = 10

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 2, rect.height))
        let bottom = max(0, min(cornerRadius, (rect.width - 2 * top) / 2, rect.height - top))

        var path = Path()
        // Outer top-left, then a concave fillet down into the (slightly inset) body.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        // Left side down to the convex bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        // Bottom edge to the convex bottom-right corner.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        // Right side up to the concave top-right fillet, then the top edge closes it.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
