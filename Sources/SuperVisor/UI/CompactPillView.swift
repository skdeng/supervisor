import SwiftUI

/// The compact live-activity content that flanks the notch cutout: `compactLeading()` to the
/// left, `compactTrailing()` to the right.
///
/// It draws NO background or offset of its own — the single morphing surface in
/// `NotchRootView` provides those — and reports each side's measured natural width through
/// bindings so the surface can size itself and keep the cutout on the physical notch. Each
/// side grows independently (volume/brightness HUD on the left, now-playing on the right).
struct CompactPillView: View {
    @EnvironmentObject private var engine: NotchEngine
    @ObservedObject private var settings = SettingsStore.shared

    /// Width of the physical notch cutout that compact content must avoid.
    let notchWidth: CGFloat
    /// Height of the notch / pill body.
    let notchHeight: CGFloat

    /// Measured natural widths of each side's content, owned by `NotchRootView`.
    @Binding var leadingWidth: CGFloat
    @Binding var trailingWidth: CGFloat

    /// Gap between content and the notch cutout.
    private var sidePadding: CGFloat {
        settings.miniLakeEnabled ? NotchTheme.compactSidePaddingMini : NotchTheme.compactSidePadding
    }

    /// Gap between content and the pill's rounded outer edge, so indicators aren't flush
    /// against the edge (and clear the concave top-corner flare).
    private var outerPadding: CGFloat {
        settings.miniLakeEnabled ? 11 : 17
    }

    var body: some View {
        HStack(spacing: 0) {
            leadingContent
                .padding(.leading, hasLeading ? outerPadding : 0)
                .padding(.trailing, hasLeading ? sidePadding : 0)
                .fixedSize()
                .background(WidthReader(width: $leadingWidth))
                .frame(width: leadingWidth, alignment: .trailing)
                .clipped()

            // Reserve the physical notch cutout so content flanks it; the surface behind
            // shows through here (and the camera cap blends the hardware notch).
            Color.clear
                .frame(width: notchWidth)

            trailingContent
                .padding(.leading, hasTrailing ? sidePadding : 0)
                .padding(.trailing, hasTrailing ? outerPadding : 0)
                .fixedSize()
                .background(WidthReader(width: $trailingWidth))
                .frame(width: trailingWidth, alignment: .leading)
                .clipped()
        }
        .frame(height: notchHeight)
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
        let entries = engine.modules.compactMap { module -> CompactEntry? in
            guard let view = module.compactLeading() else { return nil }
            return CompactEntry(moduleID: module.moduleID, view: view)
        }
        // In miniLake, keep only the first (highest-order-priority) contribution per side.
        return settings.miniLakeEnabled ? Array(entries.prefix(1)) : entries
    }

    private var trailingModules: [CompactEntry] {
        let entries = engine.modules.compactMap { module -> CompactEntry? in
            guard let view = module.compactTrailing() else { return nil }
            return CompactEntry(moduleID: module.moduleID, view: view)
        }
        return settings.miniLakeEnabled ? Array(entries.prefix(1)) : entries
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
private struct WidthReader: View {
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
