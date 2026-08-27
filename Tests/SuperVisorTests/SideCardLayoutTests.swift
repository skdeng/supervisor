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
            shadowPad: engine.sideCardShadowPad,
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

    @Test("The clipping window's leading edge sits exactly at the sheet's visible trailing edge")
    func windowLeadingEdgeAtSheetEdge() {
        for hardware in [true, false] {
            let m = metrics(sheetHeight: 400, topDrop: 0, isHardwareNotch: hardware)

            // Window and surface are centered in the same stack: the window's leading edge is
            // its center offset minus half its width.
            let windowLeadingEdge = m.windowOffsetX - m.windowWidth / 2
            #expect(windowLeadingEdge == visibleShapeWidth(isHardwareNotch: hardware) / 2)
        }
    }

    @Test("Shown, the card clears the window's leading edge by exactly the gap; hidden, its trailing edge is flush with it")
    func slidePositionsBracketTheClipEdge() {
        let m = metrics(sheetHeight: 400, topDrop: 0, isHardwareNotch: true)

        #expect(m.shownSlide == engine.sideCardGap)
        #expect(m.hiddenSlide + engine.sideCardWidth == 0)
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
