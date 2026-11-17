import Combine

/// The module-agnostic signal for new unresolved attention, held as one claim per owner (a
/// module id). The root view renders the glow while any claim stands and ends every claim when
/// the sheet opens, making the glow a one-shot indication that something new arrived since the
/// user last looked.
///
/// A claim is ended by its owner (`clear(for:)`) or by the sheet opening (`clear()`). An owner
/// that retires its banner when its claim ends therefore retires it only when the user looked
/// or the owner itself acted, never because another module acted on its own attention.
@MainActor
final class AttentionGlowCenter: ObservableObject {
    static let shared = AttentionGlowCenter()

    /// The owners whose attention is unresolved. Publishes only when it changes.
    @Published private(set) var claims: Set<String> = []
    /// Whether any claim stands. Publishes only when it changes.
    @Published private(set) var isRaised = false

    init() {}

    func raise(for owner: String) {
        guard !claims.contains(owner) else { return }
        claims.insert(owner)
        AppLog.debug(.swarm, "attention glow raised for \(owner)")
        syncRaised()
    }

    /// Ends `owner`'s claim; the glow stays while another owner's stands.
    func clear(for owner: String) {
        guard claims.contains(owner) else { return }
        claims.remove(owner)
        AppLog.debug(.swarm, "attention glow cleared for \(owner)")
        syncRaised()
    }

    /// Ends every claim: the user opened the sheet and saw everything at once.
    func clear() {
        guard !claims.isEmpty else { return }
        claims = []
        AppLog.debug(.swarm, "attention glow cleared")
        syncRaised()
    }

    /// Whether `owner`'s claim stands, as it changes. Delivers the current answer on
    /// subscription, then only changes.
    func claimPublisher(for owner: String) -> AnyPublisher<Bool, Never> {
        $claims
            .map { $0.contains(owner) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private func syncRaised() {
        let raised = !claims.isEmpty
        if raised != isRaised { isRaised = raised }
    }
}
