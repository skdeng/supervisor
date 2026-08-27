import CoreGraphics

/// Where the FileShelf's detached side card sits relative to the morphing surface, and how it
/// slides out from under it.
///
/// The card animates inside a clipping window whose leading edge sits exactly at the sheet's
/// visible trailing edge. Tucked, the card is entirely left of the window and invisible; shown,
/// it rests `gap` past the window's leading edge. Clipping at that edge is what makes the pop
/// read as the card emerging from under the sheet: on a screen with no cutout the sheet is
/// clear glass, so merely layering the card behind it would leave it visible through the
/// material the whole time. The window carries `shadowPad` of slack on its free edges so the
/// card's shadow isn't cut where nothing occludes it.
///
/// Vertically, the card spans the sheet's visible height. Over a hardware notch the sheet is
/// welded to the screen's top edge and its notch strip is the bezel — the card starts below
/// that strip so it never touches the screen edge, which only the hardware may do. On a screen
/// with no cutout the whole sheet is a floating card from `topDrop` down, so the side card
/// matches it edge to edge, strip included.
enum SideCardLayout {
    struct Metrics: Equatable {
        /// Horizontal offset of the clipping window's center from the surface's center (the
        /// ZStack both are laid out in centers its members).
        let windowOffsetX: CGFloat
        /// The clipping window's size.
        let windowWidth: CGFloat
        let windowHeight: CGFloat
        /// Top padding from the canvas's top edge to the card's (and window's) top edge.
        let top: CGFloat
        /// The card's height.
        let cardHeight: CGFloat
        /// The card's horizontal offset within the window while shown: resting `gap` past the
        /// sheet's trailing edge.
        let shownSlide: CGFloat
        /// The card's offset while tucked: its trailing edge flush with the window's leading
        /// edge, so the clip hides it entirely.
        let hiddenSlide: CGFloat
    }

    /// `visibleShapeWidth` is the sheet's VISIBLE body width — the shape's frame minus the
    /// flare gutters its body cedes while attached to a hardware notch — so the window's edge
    /// lands on the edge the eye sees, not the frame's. `minHeight` floors the card: its
    /// height tracks the sheet's, which is measured from the other modules' sections, and a
    /// quiet sheet would otherwise crush the card below what its content needs.
    static func metrics(
        visibleShapeWidth: CGFloat,
        cardWidth: CGFloat,
        gap: CGFloat,
        notchHeight: CGFloat,
        sheetHeight: CGFloat,
        topDrop: CGFloat,
        isHardwareNotch: Bool,
        shadowPad: CGFloat,
        minHeight: CGFloat
    ) -> Metrics {
        let cardHeight = max(sheetHeight + (isHardwareNotch ? 0 : notchHeight), minHeight)
        let windowWidth = gap + cardWidth + shadowPad
        return Metrics(
            windowOffsetX: visibleShapeWidth / 2 + windowWidth / 2,
            windowWidth: windowWidth,
            windowHeight: cardHeight + shadowPad,
            top: topDrop + (isHardwareNotch ? notchHeight : 0),
            cardHeight: cardHeight,
            shownSlide: gap,
            hiddenSlide: -cardWidth
        )
    }
}
