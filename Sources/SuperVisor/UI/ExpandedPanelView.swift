import SwiftUI

/// The expanded panel that drops below the notch. Stacks each enabled module's
/// `expandedSection()` vertically — the media section anchors the top, then sections a module has
/// marked urgent, with module `order` deciding within each group — inside the Liquid Glass panel
/// chrome.
///
/// The panel sizes itself to its content — it never scrolls. Content is laid out at a fixed
/// width (so nothing overflows horizontally) and adopts its natural height; that height is
/// measured and reported to the engine, which grows the morphing surface to fit exactly, up to
/// the tallest surface it will render. Content past that height dissolves into the sheet's bottom
/// edge rather than ending on a hard cut. When no module contributes a section it shows a quiet
/// empty state so the surface is never blank.
struct ExpandedPanelView: View {
    @EnvironmentObject private var engine: NotchEngine
    @ObservedObject private var urgency = SectionUrgencyCenter.shared

    /// Fixed sheet width. Content is laid out to this width, so the sheet never scrolls
    /// horizontally; overflow (there should be none) is clipped by the surface shape.
    let width: CGFloat

    /// The content's natural height, which exceeds what the surface renders once the sheet is
    /// fuller than the engine's ceiling. Drives the bottom dissolve.
    @State private var contentHeight: CGFloat = 0

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
            contentHeight = height
            engine.reportExpandedSheetHeight(height)
        }
        // No chrome of its own: the Liquid Glass panel behind it is the surface.
        // Module sections add their own cards.
        .foregroundStyle(NotchTheme.primaryForeground)
        // Applied unconditionally — the gradient is fully opaque while the content fits — so a
        // sheet that grows past the ceiling does not swap view identity and tear down the live
        // section views (and their timers) underneath it.
        .mask(
            LinearGradient(stops: overflowFadeStops, startPoint: .top, endPoint: .bottom)
        )
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
        // While a file is being dragged onto the notch, surface only the FileShelf section so
        // the drop target stands alone; other modules return once the drag ends.
        let visible = engine.isFileDragging
            ? engine.modules.filter { $0 is FileShelfModule }
            : engine.modules
        let entries = visible.compactMap { module -> SectionEntry? in
            guard let view = module.expandedSection() else { return nil }
            return SectionEntry(
                moduleID: module.moduleID,
                order: module.order,
                isPinned: module is MediaModule,
                isUrgent: urgency.urgentModuleIDs.contains(module.moduleID),
                view: view
            )
        }
        return SheetSectionOrdering.sorted(entries)
    }

    private var overflowFadeStops: [Gradient.Stop] {
        // The surface renders exactly `expandedSheetHeight` of the panel, which is the measured
        // height until the content outgrows the engine's ceiling and stops there.
        guard let band = SheetOverflowFade.band(
            contentHeight: contentHeight,
            visibleHeight: engine.expandedSheetHeight
        ) else {
            return [
                Gradient.Stop(color: .black, location: 0),
                Gradient.Stop(color: .black, location: 1),
            ]
        }
        return [
            Gradient.Stop(color: .black, location: 0),
            Gradient.Stop(color: .black, location: band.start),
            Gradient.Stop(color: .clear, location: band.end),
            Gradient.Stop(color: .clear, location: 1),
        ]
    }
}

/// A section as the sheet orders it.
protocol SheetSection {
    var moduleID: String { get }
    var order: Int { get }
    /// Whether the section anchors the top of the sheet, ahead of urgency.
    var isPinned: Bool { get }
    var isUrgent: Bool { get }
}

enum SheetSectionOrdering {
    /// A pinned section leads unconditionally: the media block is the sheet's anchor, a tall
    /// distinctive shape the eye expects at the top, and moving it costs more legibility than any
    /// reordering below it can win back.
    ///
    /// Among the rest, urgent sections lead, so the content that cannot wait is never the content
    /// that runs off the bottom of a full sheet. Module `order` decides within each group, and
    /// `moduleID` breaks a remaining tie — `sorted(by:)` gives no stability guarantee, and a sheet
    /// whose sections swapped places between builds would be unreadable.
    static func sorted<S: SheetSection>(_ sections: [S]) -> [S] {
        sections.sorted { first, second in
            if first.isPinned != second.isPinned { return first.isPinned }
            if first.isUrgent != second.isUrgent { return first.isUrgent }
            if first.order != second.order { return first.order < second.order }
            return first.moduleID < second.moduleID
        }
    }
}

/// The dissolve at the bottom of a sheet holding more content than the surface renders.
enum SheetOverflowFade {
    /// Depth of the dissolve. Deep enough to read as a fade rather than a soft edge, shallow
    /// enough that the last fully-legible row still sits above it.
    static let bandHeight: CGFloat = 44

    /// Where the dissolve begins and ends, as fractions of the content's own height — the mask
    /// spans the full natural content, of which only the top `visibleHeight` is ever on screen.
    /// `nil` when the content fits and nothing is cut off.
    static func band(contentHeight: CGFloat, visibleHeight: CGFloat) -> (start: CGFloat, end: CGFloat)? {
        guard visibleHeight > 0, contentHeight > visibleHeight else { return nil }
        return (
            start: max(0, (visibleHeight - bandHeight) / contentHeight),
            end: min(1, visibleHeight / contentHeight)
        )
    }
}

private struct SectionEntry: Identifiable, SheetSection {
    let moduleID: String
    let order: Int
    let isPinned: Bool
    let isUrgent: Bool
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
