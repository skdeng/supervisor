import Combine
import Testing

@testable import SuperVisor

@Suite("Attention glow center")
@MainActor
struct AttentionGlowCenterTests {
    @Test("One owner raises and clears the glow as a single signal")
    func singleOwner() {
        let center = AttentionGlowCenter()
        #expect(!center.isRaised)

        center.raise(for: "swarm")
        #expect(center.isRaised)
        #expect(center.claims == ["swarm"])

        center.clear(for: "swarm")
        #expect(!center.isRaised)
        #expect(center.claims.isEmpty)
    }

    @Test("When one of two owners clears, the glow stays raised and the other claim stands")
    func twoOwnersOneClears() {
        let center = AttentionGlowCenter()
        var provisor: [Bool] = []
        let subscription = center.claimPublisher(for: "provisor").sink { provisor.append($0) }
        defer { subscription.cancel() }

        center.raise(for: "swarm")
        center.raise(for: "provisor")
        center.clear(for: "swarm")

        #expect(center.isRaised)
        #expect(center.claims == ["provisor"])
        #expect(provisor == [false, true])
    }

    @Test("Clearing every claim ends both owners' claims and lowers the glow")
    func clearEndsAll() {
        let center = AttentionGlowCenter()
        var swarm: [Bool] = []
        var provisor: [Bool] = []
        let subscriptions = [
            center.claimPublisher(for: "swarm").sink { swarm.append($0) },
            center.claimPublisher(for: "provisor").sink { provisor.append($0) },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        center.raise(for: "swarm")
        center.raise(for: "provisor")
        center.clear()

        #expect(!center.isRaised)
        #expect(center.claims.isEmpty)
        #expect(swarm == [false, true, false])
        #expect(provisor == [false, true, false])
    }

    @Test("Raising a claim that stands, or clearing one that does not, publishes nothing")
    func idempotent() {
        let center = AttentionGlowCenter()
        var raised: [Bool] = []
        var claims: [Set<String>] = []
        let subscriptions = [
            center.$isRaised.sink { raised.append($0) },
            center.$claims.sink { claims.append($0) },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        center.raise(for: "swarm")
        center.raise(for: "swarm")
        center.clear(for: "provisor")
        center.raise(for: "provisor")

        #expect(raised == [false, true])
        #expect(claims == [[], ["swarm"], ["swarm", "provisor"]])

        center.clear()
        center.clear()
        #expect(raised == [false, true, false])
    }
}
