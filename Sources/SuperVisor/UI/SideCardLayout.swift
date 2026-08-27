import CoreGraphics

/// Where the FileShelf's detached side card sits relative to the morphing surface.
///
/// The card rests `gap` past the sheet's visible trailing edge. It shows and hides with a fade
/// plus a short drift from the sheet's side (`entranceShift`), so the motion points at the
/// sheet it belongs to without literally emerging from under it.
///
/// Vertically, the card spans the sheet's visible height. Over a hardware notch the sheet is
/// welded to the screen's top edge and its notch strip is the bezel — the card starts below
/// that strip so it never touches the screen edge, which only the hardware may do. On a screen
/// with no cutout the whole sheet is a floating card from `topDrop` down, so the side card
/// matches it edge to edge, strip included.
enum SideCardLayout {
    /// How far inside its resting position the card starts (and ends) its fade, toward the
    /// sheet's edge.
    static let entranceShift: CGFloat = 14

    struct Metrics: Equatable {
        /// Horizontal offset of the card's center from the surface's center (the ZStack both
        /// are laid out in centers its members).
        let offsetX: CGFloat
        /// Top padding from the canvas's top edge to the card's top edge.
        let top: CGFloat
        /// The card's height.
        let cardHeight: CGFloat
    }

    /// `visibleShapeWidth` is the sheet's VISIBLE body width — the shape's frame minus the
    /// flare gutters its body cedes while attached to a hardware notch — so the gap is held
    /// from the edge the eye sees, not the frame's. `minHeight` floors the card: its height
    /// tracks the sheet's, which is measured from the other modules' sections, and a quiet
    /// sheet would otherwise crush the card below what its content needs.
    static func metrics(
        visibleShapeWidth: CGFloat,
        cardWidth: CGFloat,
        gap: CGFloat,
        notchHeight: CGFloat,
        sheetHeight: CGFloat,
        topDrop: CGFloat,
        isHardwareNotch: Bool,
        minHeight: CGFloat
    ) -> Metrics {
        Metrics(
            offsetX: visibleShapeWidth / 2 + gap + cardWidth / 2,
            top: topDrop + (isHardwareNotch ? notchHeight : 0),
            cardHeight: max(sheetHeight + (isHardwareNotch ? 0 : notchHeight), minHeight)
        )
    }
}
