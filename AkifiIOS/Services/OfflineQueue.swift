import Foundation
import os

struct PendingOperation: Codable, Sendable, Identifiable {
    let id: String
    let timestamp: Date
    let operation: OperationType

    enum OperationType: Codable, Sendable {
        case create(CreateTransactionInput)
        case update(transactionId: String, UpdateTransactionInput)
        case delete(transactionId: String)
    }

    init(operation: OperationType) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.operation = operation
    }
}

@Observable @MainActor
final class OfflineQueue {
    private(set) var pendingOperations: [PendingOperation] = []
    private let persistence = PersistenceManager.shared
    private let transactionRepo = TransactionRepository()

    var hasPending: Bool { !pendingOperations.isEmpty }
    var pendingCount: Int { pendingOperations.count }

    init() {
        pendingOperations = persistence.loadPendingOps() ?? []
    }

    func enqueue(_ op: PendingOperation) {
        pendingOperations.append(op)
        save()
        AppLogger.data.info("Offline queue: enqueued \(op.id)")
    }

    func processQueue() async {
        guard !self.pendingOperations.isEmpty else { return }
        let count = self.pendingOperations.count
        AppLogger.data.info("Offline queue: processing \(count) operations")

        var remaining: [PendingOperation] = []

        for op in self.pendingOperations {
            do {
                switch op.operation {
                case .create(let input):
                    _ = try await transactionRepo.create(input)
                case .update(let txId, let input):
                    try await transactionRepo.update(id: txId, input)
                case .delete(let txId):
                    try await transactionRepo.delete(id: txId)
                }
                AppLogger.data.info("Offline queue: synced \(op.id)")
            } catch {
                AppLogger.data.warning("Offline queue: failed \(op.id): \(error)")
                remaining.append(op)
            }
        }

        self.pendingOperations = remaining
        self.save()
    }

    private func save() {
        persistence.savePendingOps(pendingOperations)
    }
}
