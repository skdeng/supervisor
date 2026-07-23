import SwiftUI

/// The SwiftUI root hosted by `NotchWindow`.
///
/// A single surface morphs from the notch into the sheet: while collapsed it hugs the notch with
/// compact live-activity content flanking the cutout; on expand it grows — width and height
/// spring outward — so the open reads as the notch itself expanding into the sheet rather than a
/// separate panel dropping below a static bar. The sheet is centered on the notch when open.
///
/// Over a physical cutout the surface is opaque black in every state and a solid black cap covers
/// the cutout, so the two blend. On a screen with no cutout it is clear Liquid Glass instead, and
/// detaches into a floating pill on hover (see `pillness`).
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
    @State private var peekBannerWidth: CGFloat = 0

    /// Debug: render the whole surface bright red so its exact bounds are visible. It overrides
    /// the glass material too, which is otherwise hard to pin down against a busy desktop.
    private var debugTint: Bool { settings.debugTintEnabled }
    private var surfaceColor: Color { debugTint ? .red : NotchTheme.notchBlack }

    private var geo: NotchGeometry { engine.geometry }
    private var notchW: CGFloat { max(geo.notchWidth, 80) }
    private var notchH: CGFloat { max(geo.notchHeight, 32) }
    private var isExpanded: Bool { engine.state == .expanded }
    private var peekBannerView: AnyView? {
        guard !isExpanded, engine.isPeeking else { return nil }
        return engine.activePeekBanner()
    }
    private var bannerActive: Bool { peekBannerView != nil }

    /// How far the surface has lifted off the screen's top edge: 0 while it is the notch, 1 once
    /// it has become a free-floating pill. A screen with a physical cutout never lifts — the
    /// surface *is* the hardware there, so it stays welded to the bezel.
    ///
    /// Off a notched screen there is nothing to be welded to, so pointing at it detaches it: the
    /// concave menu-bar flares unwind into round corners and it drops clear of the menu bar. The
    /// open sheet keeps that silhouette, so the pill simply grows rather than snapping back up.
    private var pillness: CGFloat {
        guard !geo.isHardwareNotch else { return 0 }
        return (engine.isHovered || isExpanded) ? 1 : 0
    }

    /// Distance the surface has actually dropped right now.
    private var topDrop: CGFloat { geo.pillTopDrop * pillness }

    private var panelW: CGFloat { engine.expandedPanelWidth }
    /// Measured sheet content height — the surface grows to exactly fit the panel (no scroll).
    private var panelH: CGFloat { engine.expandedSheetHeight }

    /// Width each side of the pill reserves: the wider side's measured content width. Both
    /// sides always match, so the pill is symmetric around the cutout and never lopsided —
    /// the shorter side simply carries black slack at its outer edge.
    private var sideWidth: CGFloat { max(leadingWidth, trailingWidth) }
    /// Collapsed width: the notch plus the (equal) flanking sides.
    private var compactWidth: CGFloat { notchW + 2 * sideWidth }
    /// The morphing surface's animated size. Pill and sheet are both centered on the notch. The
    /// frame grows by the drop so the body keeps its height as the shape lifts inside it.
    private var shapeWidth: CGFloat {
        isExpanded ? panelW : (bannerActive ? max(compactWidth, peekBannerWidth + 28) : compactWidth)
    }
    private var shapeHeight: CGFloat {
        (isExpanded ? notchH + panelH : notchH + (bannerActive ? engine.peekBannerHeight : 0))
            + topDrop
    }
    /// Tight like a pill when collapsed, rounder as the sheet opens.
    private var radius: CGFloat {
        (isExpanded || bannerActive) ? NotchTheme.panelCornerRadius : NotchTheme.pillCornerRadius
    }

    /// Grow affordance while hovering, before a click opens the sheet.
    private var hoverScale: CGFloat {
        guard engine.isHovered, !isExpanded else { return 1 }
        return geo.isHardwareNotch ? NotchTheme.notchHoverScale : NotchTheme.pillHoverScale
    }

    /// Grow from the surface's own top edge, never the screen's.
    ///
    /// A hardware notch starts at the screen's top edge, so the two coincide. A detached pill
    /// starts `topDrop` below it, and scaling about the screen edge would multiply that gap —
    /// the pill would slide further down the more it grew, instead of swelling in place.
    private var scaleAnchor: UnitPoint {
        guard shapeHeight > 0, topDrop > 0 else { return .top }
        return UnitPoint(x: 0.5, y: topDrop / shapeHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Beat aura: a blurred, artwork-tinted echo of the surface that swells with the
                // music's bass. Behind the surface and unclipped, so the glow spills past the
                // silhouette; mirrors the surface's size, hover scale, and centering offset so
                // it always hugs the same shape. Exists only while the audio tap captures.
                if settings.beatAuraEnabled && spectrum.isCapturing {
                    BeatAuraView(
                        cornerRadius: radius,
                        pillness: pillness,
                        topDrop: geo.pillTopDrop,
                        accent: spectrum.accent
                    )
                    .frame(width: shapeWidth, height: shapeHeight)
                    .scaleEffect(hoverScale, anchor: scaleAnchor)
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
                // A screen with no cutout has nothing to blend into, and a cap welded to the top
                // edge would be left stranded there the moment the surface detaches.
                if geo.isHardwareNotch {
                    NotchShape(cornerRadius: NotchTheme.pillCornerRadius)
                        .fill(surfaceColor)
                        .frame(width: notchW, height: notchH)
                        .allowsHitTesting(false)
                }
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
            // The banner grows out below the cutout without making the compact pill flare
            // sideways, and retracts with the same settled spring when its content clears.
            .animation(.spring(response: 0.34, dampingFraction: 0.9), value: bannerActive)
            // Smoothly resize the open sheet when its content (and thus measured height)
            // changes — e.g. a section appears/disappears or a file drag swaps the contents.
            .animation(.spring(response: 0.34, dampingFraction: 0.9), value: engine.expandedSheetHeight)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What the surface is made of, in whatever silhouette it currently holds.
    ///
    /// Over a physical cutout it is opaque black in every state: it is standing in for the
    /// hardware, and any translucency would betray that the notch is drawn rather than milled.
    /// A surface on a screen with no cutout has no hardware to impersonate, so it is clear
    /// Liquid Glass and lets the desktop through — as the pill and as the sheet it grows into.
    ///
    /// The glass is laid over a filled shape rather than used alone, and that fill's alpha is
    /// small but *not* zero.
    ///
    /// `NotchWindow`'s container passes a click to `NSHostingView.hitTest`, which reports a hit
    /// only where SwiftUI actually drew something — a fully transparent view is not drawn, and
    /// `.contentShape` cannot help, because it steers gesture dispatch after AppKit has already
    /// decided the event belongs to this view. `glassEffect` paints a material without
    /// contributing a body of its own. Glass alone therefore leaves the surface answering clicks
    /// only where compact content happens to cover it, and every click on the bare pill — most of
    /// it, since the middle is the reserved cutout — falls straight through to the desktop.
    ///
    /// An opaque fill is what carried the hit region before this surface became glass. The fill
    /// below restores it at an alpha that rounds to nothing on screen.
    @ViewBuilder
    private var surfaceBackground: some View {
        let shape = NotchShape(cornerRadius: radius, pillness: pillness, topDrop: geo.pillTopDrop)
        if debugTint {
            shape.fill(surfaceColor)
        } else if geo.isHardwareNotch {
            shape.fill(NotchTheme.notchBlack)
        } else {
            Color.clear
                .liquidGlass(in: shape, clear: true)
                .overlay { shape.fill(Color.white.opacity(NotchTheme.hitTestableAlpha)) }
        }
    }

    /// The single shape that morphs from the notch into the sheet.
    private var morphingSurface: some View {
        ZStack(alignment: .top) {
            // One surface in every state: the notch and the sheet it grows into are the same
            // material, so the open reads as the notch simply expanding.
            surfaceBackground

            // Compact content flanks the notch while collapsed; fades out as it expands. It
            // rides down with the surface so it stays centered in the body, never stranded in
            // the gap the pill opens above itself.
            CompactPillView(
                notchWidth: notchW,
                notchHeight: notchH,
                leadingWidth: $leadingWidth,
                trailingWidth: $trailingWidth
            )
            .frame(height: notchH)
            .offset(y: topDrop)
            .opacity(isExpanded ? 0 : 1)

            if let peekBannerView {
                peekBannerView
                    .fixedSize()
                    .background(WidthReader(width: $peekBannerWidth))
                    .frame(height: engine.peekBannerHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.top, notchH + topDrop)
                    .opacity(isExpanded ? 0 : 1)
            }

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
                    .padding(.top, notchH + topDrop)
                    .scaleEffect(isExpanded ? 1 : 0.88, anchor: .top)
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    .transition(.identity)
            }
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .clipShape(NotchShape(cornerRadius: radius, pillness: pillness, topDrop: geo.pillTopDrop))
        .contentShape(NotchShape(cornerRadius: radius, pillness: pillness, topDrop: geo.pillTopDrop))
        .scaleEffect(hoverScale, anchor: scaleAnchor)
        // A detached pill casts a shadow so it reads as hovering over the desktop rather than
        // painted onto it. A surface welded to the top edge casts none: there is nothing behind
        // it to fall on but the bezel.
        .shadow(color: .black.opacity(isExpanded ? 0.45 : 0.3 * pillness), radius: 22, y: 12)
        // Click the notch to open/close the sheet (hover only previews the grow).
        .onTapGesture { if !isExpanded { engine.toggleSheet() } }
    }

}

/// The morphing silhouette, from the MacBook notch to a free-floating pill.
///
/// At `pillness == 0` it is the classic notch: the top edge spans the full width and flares into
/// the body through small CONCAVE fillets at the top corners, so it blends into the menu bar,
/// while the bottom corners are CONVEX rounded.
///
/// At `pillness == 1` it is a pill: the shape drops `topDrop` clear of the screen's top edge and
/// the flares have curled inward into CONVEX rounded corners.
///
/// Each top corner is a single quadratic curve throughout, never two. Both the concave flare and
/// the convex corner share the same control point — the corner itself — and differ only in where
/// they begin and end. So the morph is one curve whose endpoints slide from outside the corner
/// (`-flare`, an outward flute) through flat and on to inside it (`+radius`, a rounded corner).
/// Growing a second curve alongside a shrinking first would read as a bump beside a dip.
struct NotchShape: Shape {
    /// Bottom corner radius (convex). Animatable so it can round out as the sheet opens.
    var cornerRadius: CGFloat
    /// Size of the concave flare where the notch meets the screen's top edge, at `pillness == 0`.
    var topRadius: CGFloat = 10
    /// 0 = notch flush with the screen's top edge, 1 = pill floating below it.
    var pillness: CGFloat = 0
    /// How far the shape's top edge sits below the rect's top edge at `pillness == 1`.
    var topDrop: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, pillness) }
        set {
            cornerRadius = newValue.first
            pillness = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let pill = min(max(pillness, 0), 1)
        let top = max(0, min(topRadius, rect.width / 2, rect.height))

        // The body's sides never move; only the flare above them retracts. That keeps the pill
        // concentric with the notch it grew out of.
        let left = rect.minX + top
        let right = rect.maxX - top
        let topY = rect.minY + topDrop * pill
        guard right > left, rect.maxY > topY else { return Path() }

        // How far the corner curve reaches OUTSIDE the body (the flare) and INSIDE it (the
        // rounding). They trade places across the morph, so their sum is how far down the side
        // the curve lands, and their difference is where along the top edge it starts.
        let flare = top * (1 - pill)
        let rounding = max(0, min(cornerRadius * pill, (right - left) / 2, (rect.maxY - topY) / 2))
        let cornerY = topY + flare + rounding
        let bottom = max(0, min(cornerRadius, (right - left) / 2, rect.maxY - cornerY))

        // Traversed top-left → down the left side → across the bottom → up the right side, and
        // closed by the implicit top edge. At `pillness == 0` this emits exactly the element
        // sequence the plain notch always had.
        var path = Path()
        path.move(to: CGPoint(x: left - flare + rounding, y: topY))
        path.addQuadCurve(                                      // top-left: flute → rounded corner
            to: CGPoint(x: left, y: cornerY),
            control: CGPoint(x: left, y: topY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: left + bottom, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - bottom),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: cornerY))
        path.addQuadCurve(                                      // top-right: flute → rounded corner
            to: CGPoint(x: right + flare - rounding, y: topY),
            control: CGPoint(x: right, y: topY)
        )
        path.closeSubpath()
        return path
    }
}
