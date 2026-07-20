import Combine
import Foundation

/// One user-visible operation from its start through a terminal result.
@MainActor
final class LiveOperation: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case cancelling
        case succeeded
        case failed(String)
        case cancelled
    }

    let id: UUID
    let title: String
    let detail: String?
    let startedAt: Date

    @Published private(set) var state: State = .running
    @Published private(set) var costUSD: Double?

    var onCancel: (() -> Void)?

    private var onTerminal: (() -> Void)?

    var isActive: Bool {
        state == .running || state == .cancelling
    }

    init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        startedAt: Date = Date(),
        onCancel: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.onCancel = onCancel
    }

    func cancel() {
        guard state == .running else { return }
        let cancelAction = onCancel
        onCancel = nil
        state = .cancelling
        cancelAction?()
    }

    func succeed(costUSD: Double?) {
        guard state == .running else { return }
        if let costUSD, costUSD.isFinite {
            self.costUSD = costUSD
        } else {
            self.costUSD = nil
        }
        onCancel = nil
        transition(to: .succeeded)
    }

    func fail(_ message: String) {
        guard state == .running else { return }
        onCancel = nil
        transition(to: .failed(message))
    }

    func finishCancellation() {
        guard isActive else { return }
        onCancel = nil
        transition(to: .cancelled)
    }

    func setTerminalHandler(_ handler: (() -> Void)?) {
        onTerminal = handler
    }

    private func transition(to newState: State) {
        state = newState
        onTerminal?()
        onTerminal = nil
    }
}
