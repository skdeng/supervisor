import SwiftUI

/// The expanded panel that drops below the notch. Stacks each enabled module's
/// `expandedSection()` vertically, sorted by `order` (the engine already keeps `modules`
/// sorted), inside the Liquid Glass panel chrome.
///
/// The panel sizes itself to its content — it never scrolls. Content is laid out at a fixed
/// width (so nothing overflows horizontally) and adopts its natural height; that height is
/// measured and reported to the engine, which grows the morphing surface to fit exactly. When
/// no module contributes a section it shows a quiet empty state so the surface is never blank.
struct ExpandedPanelView: View {
    @EnvironmentObject private var engine: NotchEngine

    /// Fixed sheet width. Content is laid out to this width, so the sheet never scrolls
    /// horizontally; overflow (there should be none) is clipped by the surface shape.
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.sectionSpacing) {
            if sections.isEmpty {
                emptyState
            } else {
                ForEach(sections, id: \.moduleID) { entry in
                    entry.view
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
        // Lay out at the fixed sheet width and adopt the content's natural height regardless of
        // the height the surrounding surface proposes, so the measurement below is the true
        // content height in every state (collapsed or expanded).
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(SheetHeightKey.self) { height in
            engine.reportExpandedSheetHeight(height)
        }
        // No chrome of its own: the Liquid Glass panel behind it is the surface.
        // Module sections add their own cards.
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "visionpro")
                .font(.system(size: 26, weight: .regular))
            Text("SuperVisor")
                .font(.headline)
            Text("No active modules")
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }

    private var sections: [SectionEntry] {
        // While a file is being dragged onto the notch, surface only the ClipVisor section so
        // the drop target stands alone; other modules return once the drag ends.
        let visible = engine.isFileDragging
            ? engine.modules.filter { $0 is FileShelfModule }
            : engine.modules
        return visible.compactMap { module in
            guard let view = module.expandedSection() else { return nil }
            return SectionEntry(moduleID: module.moduleID, view: view)
        }
    }
}

private struct SectionEntry: Identifiable {
    let moduleID: String
    let view: AnyView
    var id: String { moduleID }
}

/// Carries the panel's natural content height up so the engine can size the surface to fit.
private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
