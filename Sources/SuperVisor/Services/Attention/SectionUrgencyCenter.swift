import Combine

/// Modules raise this module-agnostic signal while their expanded section carries something the
/// user has to act on right now — an agent session that cannot proceed, a call in progress. The
/// sheet floats every raised section above the quiet ones, so a sheet with more content than
/// height spends that height on what cannot wait.
///
/// Urgency is coarse and rare by design. Sections keep their module `order` within the raised
/// group and within the quiet group, so the sheet's layout only ever rearranges around a genuine
/// interruption and settles back the moment it passes.
@MainActor
final class SectionUrgencyCenter: ObservableObject {
    static let shared = SectionUrgencyCenter()

    @Published private(set) var urgentModuleIDs: Set<String> = []

    private init() {}

    /// Raise or drop `moduleID`'s urgency. An unchanged flag publishes nothing, so a module may
    /// call this from a periodic tick.
    func set(_ isUrgent: Bool, for moduleID: String) {
        guard urgentModuleIDs.contains(moduleID) != isUrgent else { return }
        if isUrgent {
            urgentModuleIDs.insert(moduleID)
        } else {
            urgentModuleIDs.remove(moduleID)
        }
        AppLog.debug(.module, "section urgency \(isUrgent ? "raised" : "cleared"): \(moduleID)")
    }
}
