import Combine
import Foundation

/// Holds currently visible operations and removes completed entries after a short grace period.
@MainActor
final class OperationCenter: ObservableObject {
    @Published private(set) var operations: [LiveOperation] = []

    private let terminalLifetime: Duration = .seconds(6)
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    var onPresenceChanged: (() -> Void)?

    func begin(
        title: String,
        detail: String? = nil,
        onCancel: (() -> Void)? = nil
    ) -> LiveOperation {
        let wasEmpty = operations.isEmpty
        let operation = LiveOperation(title: title, detail: detail, onCancel: onCancel)
        let operationID = operation.id
        operation.setTerminalHandler { [weak self] in
            self?.scheduleExpiry(for: operationID)
        }
        operations.insert(operation, at: 0)
        if wasEmpty {
            onPresenceChanged?()
        }
        return operation
    }

    func remove(_ id: UUID) {
        let hadOperations = !operations.isEmpty
        expiryTasks.removeValue(forKey: id)?.cancel()
        if let operation = operations.first(where: { $0.id == id }) {
            operation.setTerminalHandler(nil)
        }
        operations.removeAll { $0.id == id }
        if hadOperations, operations.isEmpty {
            onPresenceChanged?()
        }
    }

    func remove(_ operation: LiveOperation) {
        remove(operation.id)
    }

    func removeAll() {
        let hadOperations = !operations.isEmpty
        for task in expiryTasks.values {
            task.cancel()
        }
        expiryTasks.removeAll()
        for operation in operations {
            operation.setTerminalHandler(nil)
        }
        operations.removeAll()
        if hadOperations {
            onPresenceChanged?()
        }
    }

    private func scheduleExpiry(for id: UUID) {
        guard operations.contains(where: { $0.id == id }) else { return }
        expiryTasks.removeValue(forKey: id)?.cancel()
        expiryTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: terminalLifetime)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            remove(id)
        }
    }
}
