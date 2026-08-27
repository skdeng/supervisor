import CoreGraphics
import Testing

@testable import SuperVisor

@MainActor
@Suite("Side card layout")
struct SideCardLayoutTests {
    private let engine = NotchEngine()

    /// The sheet's visible body width while expanded: the panel width minus the flare gutters
    /// the shape's body cedes while attached to a hardware notch.
    private func visibleShapeWidth(isHardwareNotch: Bool) -> CGFloat {
        engine.expandedPanelWidth - 2 * NotchShape.defaultTopRadius
            * (isHardwareNotch ? 1 : 0)
    }

    private func metrics(
        sheetHeight: CGFloat,
        topDrop: CGFloat,
        isHardwareNotch: Bool
    ) -> SideCardLayout.Metrics {
        SideCardLayout.metrics(
            visibleShapeWidth: visibleShapeWidth(isHardwareNotch: isHardwareNotch),
            cardWidth: engine.sideCardWidth,
            gap: engine.sideCardGap,
            notchHeight: 32,
            sheetHeight: sheetHeight,
            topDrop: topDrop,
            isHardwareNotch: isHardwareNotch,
            minHeight: engine.sideCardMinHeight
        )
    }

    @Test("Over a hardware notch the card starts below the notch strip and matches the sheet's content height")
    func hardwareNotchFrame() {
        let m = metrics(sheetHeight: 500, topDrop: 0, isHardwareNotch: true)

        #expect(m.top == 32)
        #expect(m.cardHeight == 500)
    }

    @Test("On a screen with no cutout the card matches the floating sheet edge to edge, strip included")
    func flatScreenFrame() {
        let m = metrics(sheetHeight: 500, topDrop: 8, isHardwareNotch: false)

        #expect(m.top == 8)
        #expect(m.cardHeight == 532)
    }

    @Test("A short sheet cannot crush the card below its height floor")
    func shortSheetFlooredToMinimum() {
        let m = metrics(
            sheetHeight: engine.minExpandedSheetHeight,
            topDrop: 0,
            isHardwareNotch: true
        )

        #expect(m.cardHeight == engine.sideCardMinHeight)
    }

    @Test("The card clears the sheet's visible trailing edge by exactly the gap")
    func cardClearsSheetByGap() {
        for hardware in [true, false] {
            let m = metrics(sheetHeight: 400, topDrop: 0, isHardwareNotch: hardware)

            // Card and surface are centered in the same stack: the card's leading edge is its
            // center offset minus half its width.
            let cardLeadingEdge = m.offsetX - engine.sideCardWidth / 2
            let sheetTrailingEdge = visibleShapeWidth(isHardwareNotch: hardware) / 2
            #expect(cardLeadingEdge - sheetTrailingEdge == engine.sideCardGap)
        }
    }

    @Test("The card, its gap, and its shadow slack fit inside the fixed canvas on both screen classes")
    func cardContainedByCanvas() {
        let hardwareGeo = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchRect: CGRect(x: 656, y: 950, width: 200, height: 32),
            isHardwareNotch: true
        )
        var flatGeo = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchRect: CGRect(x: 656, y: 950, width: 200, height: 32),
            isHardwareNotch: false
        )
        flatGeo.pillTopDrop = 8

        for geo in [hardwareGeo, flatGeo] {
            let canvasHalfWidth = engine.canvasFrame(for: geo).width / 2
            let cardTrailingEdge = engine.expandedPanelWidth / 2
                + engine.sideCardGap + engine.sideCardWidth + engine.sideCardShadowPad
            #expect(cardTrailingEdge <= canvasHalfWidth)
        }
    }
}
