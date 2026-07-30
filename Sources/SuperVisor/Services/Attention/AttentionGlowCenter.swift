import Combine

/// Modules raise this module-agnostic signal for new unresolved attention. The root view renders
/// it and clears it when the sheet opens, making the glow a one-shot indication that something
/// new arrived since the user last looked.
@MainActor
final class AttentionGlowCenter: ObservableObject {
    static let shared = AttentionGlowCenter()

    @Published private(set) var isRaised = false

    private init() {}

    func raise() {
        guard !isRaised else { return }
        isRaised = true
        AppLog.debug(.swarm, "attention glow raised")
    }

    func clear() {
        guard isRaised else { return }
        isRaised = false
        AppLog.debug(.swarm, "attention glow cleared")
    }
}
