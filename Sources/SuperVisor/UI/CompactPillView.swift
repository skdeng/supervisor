import SwiftUI

/// The compact live-activity content that flanks the notch cutout: `compactLeading()` to the
/// left, `compactTrailing()` to the right.
///
/// It draws NO background or offset of its own — the single morphing surface in
/// `NotchRootView` provides those — and reports each side's measured natural width through
/// bindings so the surface can size itself. Both sides RENDER at the wider side's width
/// (content hugs the pill's outer edge; the slack sits against the cutout, where it reads
/// as notch body), so the pill is always symmetric around the physical notch.
struct CompactPillView: View {
    @EnvironmentObject private var engine: NotchEngine

    /// Width of the reserved center gap the content flanks: the notch cutout, plus the hover
    /// swell and any banner-driven extra width — the gap flexes so the content columns keep
    /// their natural, unscaled size and hug the surface's outer edges at a constant margin.
    let cutoutWidth: CGFloat
    /// Height of the notch / pill strip at the current hover growth.
    let stripHeight: CGFloat
    /// Gap between content and the surface's FRAME edge, sized by `NotchRootView` so the visible
    /// side margin matches the vertical margin around standard-height content. While the surface
    /// is attached it additionally covers the flare inset the body sides tuck behind.
    let edgePadding: CGFloat

    /// Measured natural widths of each side's content, owned by `NotchRootView`.
    @Binding var leadingWidth: CGFloat
    @Binding var trailingWidth: CGFloat

    /// Gap between content and the notch cutout.
    private let sidePadding: CGFloat = NotchTheme.compactSidePadding

    /// Both side slots render at the wider side's measured width, keeping the pill symmetric.
    private var sideWidth: CGFloat { max(leadingWidth, trailingWidth) }

    var body: some View {
        HStack(spacing: 0) {
            leadingContent
                .padding(.leading, hasLeading ? edgePadding : 0)
                .padding(.trailing, hasLeading ? sidePadding : 0)
                .fixedSize()
                .background(WidthReader(width: $leadingWidth))
                .frame(width: sideWidth, alignment: .leading)
                .clipped()

            // Reserve the center gap so content flanks it; the surface behind shows through
            // here (and the camera cap blends the hardware notch).
            Color.clear
                .frame(width: cutoutWidth)

            trailingContent
                .padding(.leading, hasTrailing ? sidePadding : 0)
                .padding(.trailing, hasTrailing ? edgePadding : 0)
                .fixedSize()
                .background(WidthReader(width: $trailingWidth))
                .frame(width: sideWidth, alignment: .trailing)
                .clipped()
        }
        .frame(height: stripHeight)
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    private var hasLeading: Bool { !leadingModules.isEmpty }
    private var hasTrailing: Bool { !trailingModules.isEmpty }

    @ViewBuilder
    private var leadingContent: some View {
        HStack(spacing: 6) {
            ForEach(leadingModules, id: \.moduleID) { entry in
                entry.view
            }
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        HStack(spacing: 6) {
            ForEach(trailingModules, id: \.moduleID) { entry in
                entry.view
            }
        }
    }

    private var leadingModules: [CompactEntry] {
        engine.modules.compactMap { module -> CompactEntry? in
            guard let view = module.compactLeading() else { return nil }
            return CompactEntry(moduleID: module.moduleID, view: view)
        }
    }

    private var trailingModules: [CompactEntry] {
        engine.modules.compactMap { module -> CompactEntry? in
            guard let view = module.compactTrailing() else { return nil }
            return CompactEntry(moduleID: module.moduleID, view: view)
        }
    }
}

/// A compact contribution paired with its owning module id for stable identity.
private struct CompactEntry: Identifiable {
    let moduleID: String
    let view: AnyView
    var id: String { moduleID }
}

/// Reports the natural width of the view it backs through a binding. The update is wrapped in
/// `withAnimation` so the pill grows/shrinks smoothly when content appears, changes, or
/// disappears: the measured width is set off-cycle by the GeometryReader, so an ancestor
/// `.animation(value:)` doesn't reliably catch it — an explicit animation transaction does.
struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, newWidth in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        width = newWidth
                    }
                }
        }
    }
}
