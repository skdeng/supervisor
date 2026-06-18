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

    private var panelW: CGFloat { engine.expandedPanelSize.width }
    private var panelH: CGFloat { engine.expandedPanelSize.height }

    /// Collapsed width: the notch plus whatever compact content flanks it.
    private var compactWidth: CGFloat { notchW + leadingWidth + trailingWidth }
    /// The morphing surface's animated size.
    private var shapeWidth: CGFloat { isExpanded ? panelW : compactWidth }
    private var shapeHeight: CGFloat { isExpanded ? notchH + panelH : notchH }
    /// While collapsed, shift the asymmetric pill so the cutout stays on the physical notch;
    /// while expanded, the sheet is centered on the notch (offset 0).
    private var shapeOffsetX: CGFloat { isExpanded ? 0 : (trailingWidth - leadingWidth) / 2 }
    /// Tight like a pill when collapsed, rounder as the sheet opens.
    private var radius: CGFloat { isExpanded ? NotchTheme.panelCornerRadius : NotchTheme.pillCornerRadius }

    /// Subtle grow affordance while hovering (before a click opens the sheet). Anchored at the
    /// top edge so it grows down and outward, never above the screen's top.
    private var hoverScale: CGFloat { (engine.isHovered && !isExpanded) ? 1.06 : 1.0 }

    /// Truly idle: nothing to show. We render no surface at all so the bare hardware notch
    /// shows at exactly its own size — our pill never overhangs the physical cutout. In debug
    /// tint we always render so the red bounds stay visible.
    private var isIdle: Bool {
        !debugTint && !isExpanded && !engine.isHovered && leadingWidth < 0.5 && trailingWidth < 0.5
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // ONE surface: the notch itself grows and becomes the sheet — not a separate
                // panel dropping below a static bar. Hidden entirely while idle so the bare
                // hardware notch is all that shows.
                morphingSurface
                    .opacity(isIdle ? 0 : 1)

                // Camera cap: solid black over the physical notch so the hardware cutout blends
                // whenever the surface is showing. Pinned to the notch center (never offset).
                // Purely visual — it must not swallow clicks, so taps on the notch area reach
                // the surface's tap gesture below.
                NotchShape(cornerRadius: NotchTheme.pillCornerRadius)
                    .fill(surfaceColor)
                    .frame(width: notchW, height: notchH)
                    .allowsHitTesting(false)
                    .opacity(isIdle ? 0 : 1)
            }
            // One spring keyed on `isExpanded`, so expand and retract use identical params;
            // lower damping makes the morph noticeably springier.
            .animation(.spring(response: 0.42, dampingFraction: 0.68), value: isExpanded)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: engine.isHovered)

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

            // The sheet's content fills the surface once expanded; fades in a beat after the
            // surface has grown.
            ExpandedPanelView(size: engine.expandedPanelSize)
                .padding(.top, notchH)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
                .animation(.easeOut(duration: 0.16).delay(isExpanded ? 0.16 : 0), value: isExpanded)
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .clipShape(NotchShape(cornerRadius: radius))
        .contentShape(NotchShape(cornerRadius: radius))
        .scaleEffect(hoverScale, anchor: .top)
        .offset(x: shapeOffsetX)
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
