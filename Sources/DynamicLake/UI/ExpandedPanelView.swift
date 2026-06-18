import SwiftUI

/// The expanded panel that drops below the notch. Stacks each enabled module's
/// `expandedSection()` vertically, sorted by `order` (the engine already keeps `modules`
/// sorted), inside the Liquid Glass panel chrome. When no module contributes a section it
/// shows a quiet empty state so the surface is never blank.
struct ExpandedPanelView: View {
    @EnvironmentObject private var engine: NotchEngine

    let size: CGSize

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
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
            .padding(NotchTheme.panelPadding)
            // Pin to the panel width (not maxWidth: .infinity) so a section's intrinsic/
            // fixed-size content can't widen the scroll content and introduce a horizontal
            // scroll. Overflow is clipped to the panel instead.
            .frame(width: size.width, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // No chrome of its own: the Liquid Glass panel behind it is the surface.
        // Module sections add their own cards.
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "water.waves")
                .font(.system(size: 26, weight: .regular))
            Text("DynamicLake")
                .font(.headline)
            Text("No active modules")
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(minHeight: size.height - 2 * NotchTheme.panelPadding)
    }

    private var sections: [SectionEntry] {
        engine.modules.compactMap { module in
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
