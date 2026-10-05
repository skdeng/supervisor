import Foundation
import Testing
@testable import SuperVisor

/// The collapsed surface's width while a peek banner hangs below a hardware notch. The attached
/// shape's body is `NotchShape.defaultTopRadius` inside the frame per side, so the frame has to
/// exceed the cutout by that inset on each side for the visible strip to span the cutout.
@MainActor
struct BelowNotchBannerWidthTests {
    private let inset = 2 * NotchShape.defaultTopRadius

    @Test("A bare notch widens the frame so the banner body spans the cutout")
    func bareNotchSpansCutout() {
        let width = NotchRootView.belowNotchBannerSurfaceWidth(
            compactWidth: 185, bannerWidth: 170, notchWidth: 185
        )
        #expect(width == 185 + inset)
    }

    @Test("Compact content already wider than the cutout plus flares keeps its own width")
    func compactContentWins() {
        let width = NotchRootView.belowNotchBannerSurfaceWidth(
            compactWidth: 320, bannerWidth: 170, notchWidth: 185
        )
        #expect(width == 320)
    }

    @Test("A banner wider than the cutout plus flares sizes the surface")
    func wideBannerWins() {
        let width = NotchRootView.belowNotchBannerSurfaceWidth(
            compactWidth: 185, bannerWidth: 260, notchWidth: 185
        )
        #expect(width == 260)
    }

    @Test("The hover swell, which adds the flare inset per side, is never shrunk by the floor")
    func hoverSwellIsNotReduced() {
        let hovered = 185 + 2 * NotchTheme.hoverWidthPad
        let width = NotchRootView.belowNotchBannerSurfaceWidth(
            compactWidth: hovered, bannerWidth: 170, notchWidth: 185
        )
        #expect(width == hovered)
        #expect(width >= 185 + inset)
    }
}
