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
    @ObservedObject private var attentionGlow = AttentionGlowCenter.shared

    /// Measured natural widths of each side's compact content; drive the collapsed width and
    /// the cutout-centering offset.
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var peekBannerContentWidth: CGFloat = 0
    /// Natural size of an inline peek's content; nil until the probe first reports, so a banner
    /// that genuinely measures zero renders visibly broken rather than invisibly stuck. Never
    /// reset when the peek ends: `inlinePeek` already makes a stale value inert, while clearing
    /// it would re-run the measure on the next peek — popping the strip open on the file-drag
    /// collapse path, and racing the new content when one peek replaces another.
    @State private var centerSize: CGSize?

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
    /// Where an active peek banner presents. Over a physical cutout it drops below the notch as
    /// its own strip; with no cutout to hang off, it rides in the pill's own gap and the pill
    /// grows around it, so the surface stays a single row.
    private var bannerBelow: Bool { bannerActive && geo.isHardwareNotch }
    private var inlinePeek: Bool { bannerActive && !geo.isHardwareNotch }

    /// How far the surface has lifted off the screen's top edge: 0 while it is the notch, 1 once
    /// it has become a free-floating pill. A screen with a physical cutout never lifts — the
    /// surface *is* the hardware there, so it stays welded to the bezel.
    ///
    /// Off a notched screen there is nothing to be welded to, so pointing at it detaches it: the
    /// concave menu-bar flares unwind into round corners and it drops clear of the menu bar. The
    /// open sheet and a peek banner keep that silhouette — both are floating cards, and a wide
    /// banner surface left flush at the top edge would poke its concave flares into the menu bar
    /// as stray curls.
    private var pillness: CGFloat {
        guard !geo.isHardwareNotch else { return 0 }
        return (engine.isHovered || isExpanded || bannerActive) ? 1 : 0
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

    /// Grow affordance while hovering, before a click opens the sheet. Applied as LAYOUT
    /// growth — a larger frame the vector shape redraws into — never a render transform:
    /// `scaleEffect` would rasterize the compact and banner content along with the surface
    /// and blur every glyph.
    private var hoverGrowth: CGFloat {
        guard engine.isHovered, !isExpanded else { return 1 }
        return geo.isHardwareNotch ? NotchTheme.notchHoverScale : NotchTheme.pillHoverScale
    }

    /// The bare notch strip's height under hover growth — the floor `stripH` swells up from; a
    /// banner strip below the notch never grows.
    private var grownNotchH: CGFloat { notchH * hoverGrowth }
    /// Collapsed width: the notch plus the (equal) flanking sides, plus a fixed per-side pad
    /// while hovered (see `NotchTheme.hoverWidthPad` for why width growth is additive).
    private var compactWidth: CGFloat {
        notchW + 2 * sideWidth + (hoverGrowth > 1 ? 2 * NotchTheme.hoverWidthPad : 0)
    }
    /// The center gap an inline peek needs: its content plus a margin on each side.
    ///
    /// Flanked, that margin is the gap the compact columns already hold toward the cutout, so the
    /// content sits a full 16pt clear of each neighbour — the flanks are unrelated live activities
    /// and want more separation from the banner than the banner's own content does from the pill's
    /// edge. Alone in a bare pill there is nothing to separate from, so the inset is
    /// `surfaceEdgePad`: the content's horizontal margin then equals its vertical one.
    private var centerGap: CGFloat {
        (centerSize?.width ?? 0)
            + 2 * (sideWidth > 0 ? NotchTheme.compactSidePadding : surfaceEdgePad)
    }

    /// The below-notch banner's natural surface width. The probe measures only intrinsic content;
    /// adding the current edge padding here keeps the surface demand synchronized with the visible
    /// row while hover animates that padding.
    private var peekBannerWidth: CGFloat {
        peekBannerContentWidth + 2 * surfaceEdgePad
    }

    /// Collapsed surface width: the banner demand already includes the shared edge padding, so it
    /// IS the required surface width — any extra allowance would push the banner row's content out
    /// of alignment with the pill row's.
    ///
    /// The inline branch adds no hover term of its own: hover growth already arrives through
    /// `surfaceEdgePad` (which widens the gap) and through the flanking columns' own padding, and
    /// adding `hoverWidthPad` on top would stack a second swell over that one. The clamp keeps
    /// the surface inside the fixed canvas that would otherwise clip it — and applies to the
    /// banner's demand alone, so an oversized banner degrades by losing gap width while
    /// `cutoutWidth` (their difference) stays non-negative.
    private var collapsedWidth: CGFloat {
        if inlinePeek {
            return max(compactWidth, min(2 * sideWidth + centerGap, engine.collapsedWidthLimit))
        }
        return bannerBelow ? max(compactWidth, peekBannerWidth) : compactWidth
    }

    /// Height of the pill strip. An inline peek swells it to clear its content by the same margin
    /// the pill holds at its sides, in every hover state. With no inline peek this is exactly
    /// `grownNotchH`, so one value serves both screens everywhere the strip is laid out.
    private var stripH: CGFloat {
        max(grownNotchH, inlinePeek ? (centerSize?.height ?? 0) + 2 * surfaceEdgePad : 0)
    }

    /// The cutout gap `CompactPillView` reserves between its two content columns, and where an
    /// inline peek renders. Hover growth and any banner-driven extra width land entirely in this
    /// gap: the columns keep their natural size and hug the surface's outer edges at a constant
    /// margin, riding outward with the hover swell so content hugs the sides in every state.
    private var cutoutWidth: CGFloat { collapsedWidth - 2 * sideWidth }

    /// Horizontal inset from the surface's frame edge to its content. One value serves the compact
    /// row and a peek-banner row below it, so the two rows' content edges align by construction;
    /// it is also what an inline peek clears the strip by, top and bottom.
    ///
    /// The VISIBLE side margin must equal the vertical margin standard-height compact content
    /// holds in the BARE notch strip, `(grownNotchH − compactContentHeight) / 2` — an inline peek
    /// swells the strip past that floor, granting flanking content extra top/bottom clearance
    /// while its side margin holds. While the surface is attached, the shape's body sides tuck
    /// `NotchShape.defaultTopRadius` behind the concave flares, so the frame-relative padding
    /// carries that extra inset on top; detached, the body fills the frame and the padding IS the
    /// visible margin.
    private var surfaceEdgePad: CGFloat {
        (grownNotchH - NotchTheme.compactContentHeight) / 2
            + NotchShape.defaultTopRadius * (1 - pillness)
    }

    /// The morphing surface's animated size. Pill and sheet are both centered on the notch. The
    /// frame grows by the drop so the body keeps its height as the shape lifts inside it.
    ///
    /// The expanded frame subtracts the flare gutters the shape's body cedes at low pillness
    /// (`topRadius` per side attached, none detached), so the sheet's VISIBLE body is
    /// `panelW − 2·topRadius` wide on every screen — the panel content, laid out at `panelW`
    /// with its own padding, lands at the same margins whether the sheet is welded to a
    /// hardware notch or floating as glass.
    private var shapeWidth: CGFloat {
        isExpanded ? panelW - 2 * NotchShape.defaultTopRadius * pillness : collapsedWidth
    }
    private var shapeHeight: CGFloat {
        (isExpanded ? notchH + panelH : stripH + (bannerBelow ? engine.peekBannerHeight : 0))
            + topDrop
    }
    /// Tight like a pill when collapsed, rounder as the sheet opens. A banner strip below the
    /// notch is a card in its own right and takes the sheet's radius; an inline peek is still the
    /// pill, just a taller one.
    private var radius: CGFloat {
        (isExpanded || bannerBelow) ? NotchTheme.panelCornerRadius : NotchTheme.pillCornerRadius
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
                    .allowsHitTesting(false)
                }

                if attentionGlow.isRaised && !isExpanded {
                    // Sized `spill` beyond the surface on every side (and re-centered on it,
                    // since the ZStack top-aligns) so the glow ring is never cut at its own
                    // frame where the silhouette touches the frame's edges.
                    AttentionGlowView(
                        cornerRadius: radius,
                        pillness: pillness,
                        topDrop: geo.pillTopDrop
                    )
                    .frame(
                        width: shapeWidth + 2 * AttentionGlowView.spill,
                        height: shapeHeight + 2 * AttentionGlowView.spill
                    )
                    .offset(y: -AttentionGlowView.spill)
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
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    AttentionGlowCenter.shared.clear()
                }
            }
            // Only SwiftUI's layout knows how big the collapsed surface actually got, and the
            // engine's hit-test and hover rects have to contain it.
            .onChange(of: collapsedWidth, initial: true) { _, _ in reportCollapsedSurface() }
            .onChange(of: stripH) { _, _ in reportCollapsedSurface() }

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
    ///
    /// The material is the stack's `background`, never a stack member. A background is laid out
    /// to the frame the stack is held at, whereas a ZStack proposes its own union size to a
    /// flexible member. The pre-built sheet overflows that frame while the pill is hovered, so a
    /// member `Color.clear` would take the sheet's size and hand the glass a sheet-sized shape:
    /// the visible pill would be a cutout from a pane whose refraction rims lie well outside it,
    /// and every hover morph would slide those rims off the pill and back onto it in its last
    /// frame.
    private var morphingSurface: some View {
        // Sampled once: each read walks the modules and wraps a fresh AnyView.
        let banner = peekBannerView
        return ZStack(alignment: .top) {
            // Compact content flanks the notch while collapsed; fades out as it expands. It
            // rides down with the surface so it stays centered in the body, never stranded in
            // the gap the pill opens above itself.
            CompactPillView(
                cutoutWidth: cutoutWidth,
                stripHeight: stripH,
                edgePadding: surfaceEdgePad,
                leadingWidth: $leadingWidth,
                trailingWidth: $trailingWidth,
                centerContent: inlinePeek ? banner : nil,
                centerSize: $centerSize
            )
            .frame(height: stripH)
            .offset(y: topDrop)
            .opacity(isExpanded ? 0 : 1)

            if bannerBelow, let peekBannerView = banner {
                // The visible banner is explicitly bounded to the surface so the prebuilt
                // expanded panel cannot widen this flexible row behind the collapsed clip. Its
                // internal spacer absorbs any surface growth and pins the actions to the trailing
                // content edge. The hidden fixed-size probe measures intrinsic content only;
                // `peekBannerWidth` adds the live edge padding in the same layout pass.
                peekBannerView
                    .padding(.horizontal, surfaceEdgePad)
                    .frame(width: shapeWidth)
                    .frame(height: engine.peekBannerHeight)
                    .background(
                        peekBannerView
                            .fixedSize()
                            .hidden()
                            .background(WidthReader(width: $peekBannerContentWidth))
                    )
                    .padding(.top, stripH + topDrop)
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
                    // A hover-exit close removes the panel in the transaction that starts the
                    // close, so its exit transition carries the fade-and-shrink the modifiers
                    // above animate when the sheet closes under a still-hovering cursor; both
                    // closes look alike. On insertion the transition starts where those
                    // modifiers already hold a hidden panel, so a hover shows nothing.
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .top)))
            }
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        // One surface in every state: the notch and the sheet it grows into are the same
        // material, so the open reads as the notch simply expanding.
        .background(alignment: .top) { surfaceBackground }
        .clipShape(NotchShape(cornerRadius: radius, pillness: pillness, topDrop: geo.pillTopDrop))
        .contentShape(NotchShape(cornerRadius: radius, pillness: pillness, topDrop: geo.pillTopDrop))
        // A detached pill casts a shadow so it reads as hovering over the desktop rather than
        // painted onto it. A surface welded to the top edge casts none: there is nothing behind
        // it to fall on but the bezel.
        .shadow(color: .black.opacity(isExpanded ? 0.45 : 0.3 * pillness), radius: 22, y: 12)
        // Click the notch to open/close the sheet (hover only previews the grow).
        .onTapGesture { if !isExpanded { engine.toggleSheet() } }
        // The tooltip host lives outside the surface clip so labels can extend beyond the silhouette.
        .notchTooltipHost()
    }

    private func reportCollapsedSurface() {
        engine.reportCollapsedSurface(width: collapsedWidth, stripHeight: stripH)
    }
}

/// The morphing silhouette, from the MacBook notch to a free-floating pill.
///
/// At `pillness == 0` it is the classic notch: the top edge spans the full width and flares into
/// the body through small CONCAVE fillets at the top corners, so it blends into the menu bar,
/// while the bottom corners are CONVEX rounded.
///
/// At `pillness == 1` it is a pill: the shape drops `topDrop` clear of the screen's top edge, the
/// flares have curled inward into CONVEX rounded corners, and the body's sides — tucked behind
/// the flares while attached — have slid out to span the full rect, so the floating pill fills
/// its frame edge to edge.
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
    /// Also the body's per-side inset behind those flares, which callers sizing a frame around
    /// the VISIBLE body need to account for.
    static let defaultTopRadius: CGFloat = 10
    var topRadius: CGFloat = NotchShape.defaultTopRadius
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

        // How far the corner curve reaches OUTSIDE the body (the flare) and INSIDE it (the
        // rounding). They trade places across the morph, so their sum is how far down the side
        // the curve lands, and their difference is where along the top edge it starts.
        let flare = top * (1 - pill)

        // The flare doubles as the body's side inset: at `pillness == 0` the top edge spans the
        // full rect and the sides tuck in behind the flares. As the surface detaches, the flares
        // unwind and the sides slide out to the rect's edges, so the floating pill fills its
        // frame — content padded from the frame edge keeps that margin from the VISIBLE edge,
        // instead of losing `topRadius` of it to a phantom gutter the clip then cuts into.
        let left = rect.minX + flare
        let right = rect.maxX - flare
        let topY = rect.minY + topDrop * pill
        guard right > left, rect.maxY > topY else { return Path() }
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
