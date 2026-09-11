import Foundation
import Supabase
import os

struct PendingOperation: Codable, Sendable, Identifiable {
    let id: String
    let timestamp: Date
    let operation: OperationType
    /// Replay attempts that failed with a non-transport error. Transport
    /// failures (no network) don't count — they halt the round instead.
    var attempts: Int
    var lastErrorDescription: String?

    enum OperationType: Codable, Sendable {
        case create(CreateTransactionInput)
        case update(transactionId: String, UpdateTransactionInput)
        case delete(transactionId: String)
    }

    init(operation: OperationType) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.operation = operation
        self.attempts = 0
        self.lastErrorDescription = nil
    }

    /// Copy with a replaced operation, preserving identity/ordering metadata.
    /// Used when coalescing folds an update into a queued create.
    init(recreating original: PendingOperation, operation: OperationType) {
        self.id = original.id
        self.timestamp = original.timestamp
        self.operation = operation
        self.attempts = original.attempts
        self.lastErrorDescription = original.lastErrorDescription
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, operation, attempts, lastErrorDescription
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        operation = try c.decode(OperationType.self, forKey: .operation)
        // Tolerant decode: queue files written before offline-v2 lack these.
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastErrorDescription = try c.decodeIfPresent(String.self, forKey: .lastErrorDescription)
    }

    /// The transaction this operation targets (client id for creates).
    var targetTransactionId: String? {
        switch operation {
        case .create(let input): return input.id
        case .update(let txId, _): return txId
        case .delete(let txId): return txId
        }
    }
}

@Observable @MainActor
final class OfflineQueue {
    private(set) var pendingOperations: [PendingOperation] = []
    /// Operations that failed `maxAttempts` times with a permanent error.
    /// Kept out of the replay path so one poisoned op can't block the queue;
    /// surfaced in Settings for the user to discard.
    private(set) var deadLetterOperations: [PendingOperation] = []
    /// True while a replay round is in flight — guards against `loadAll()`
    /// racing the reconnect hook into double-replaying the same op.
    private(set) var isProcessing = false

    private let persistence: PersistenceManager
    private let transactionRepo = TransactionRepository()

    static let maxAttempts = 3

    var hasPending: Bool { !pendingOperations.isEmpty }
    var pendingCount: Int { pendingOperations.count }

    init(persistence: PersistenceManager = .shared) {
        self.persistence = persistence
        pendingOperations = persistence.loadPendingOps() ?? []
        deadLetterOperations = persistence.loadDeadLetterOps() ?? []
    }

    func enqueue(_ op: PendingOperation) {
        pendingOperations = Self.coalesce(pendingOperations, adding: op)
        save()
        AppLogger.data.info("Offline queue: enqueued \(op.id), depth \(self.pendingOperations.count)")
    }

    /// True when the queue still holds the CREATE for this transaction —
    /// i.e. the row exists only locally and its id (for RPC-created rows)
    /// may not survive the sync.
    func hasQueuedCreate(for transactionId: String) -> Bool {
        pendingOperations.contains { op in
            if case .create(let input) = op.operation { return input.id == transactionId }
            return false
        }
    }

    func discardDeadLetters() {
        deadLetterOperations = []
        persistence.saveDeadLetterOps(deadLetterOperations)
    }

    // MARK: - Coalescing

    /// Folds the incoming op into the queue so dependent chains collapse:
    /// - update of a queued create → merged into the create's payload
    /// - delete of a queued create → create (and its updates) removed,
    ///   nothing reaches the server
    /// - delete of a synced row → queued updates of that row dropped as
    ///   obsolete, delete appended
    /// Pure and static for unit testing.
    static func coalesce(_ queue: [PendingOperation], adding op: PendingOperation) -> [PendingOperation] {
        switch op.operation {
        case .create:
            return queue + [op]

        case .update(let txId, let update):
            if let idx = queue.firstIndex(where: { isCreate($0, of: txId) }),
               case .create(let input) = queue[idx].operation {
                var merged = queue
                merged[idx] = PendingOperation(
                    recreating: queue[idx],
                    operation: .create(input.applying(update))
                )
                return merged
            }
            return queue + [op]

        case .delete(let txId):
            if queue.contains(where: { isCreate($0, of: txId) }) {
                // The row never reached the server — cancel everything.
                return queue.filter { $0.targetTransactionId != txId }
            }
            return queue.filter { !isUpdate($0, of: txId) } + [op]
        }
    }

    private static func isCreate(_ op: PendingOperation, of txId: String) -> Bool {
        if case .create(let input) = op.operation { return input.id == txId }
        return false
    }

    private static func isUpdate(_ op: PendingOperation, of txId: String) -> Bool {
        if case .update(let id, _) = op.operation { return id == txId }
        return false
    }

    // MARK: - Replay

    enum ReplayOutcome {
        /// The server already has this state (duplicate create / missing
        /// row on delete) — drop the op as synced.
        case treatAsSynced
        /// Transport-level failure — stop the round, keep ALL remaining ops
        /// in order so dependent chains never replay out of order.
        case haltTransport
        /// Permanent-looking error, attempts left — keep for the next round.
        case retryCounted
        /// Failed `maxAttempts` times — move to the dead-letter list.
        case deadLetter
    }

    /// Classifies a replay failure. Pure and static for unit testing.
    static func outcome(
        for error: Error,
        operation: PendingOperation.OperationType,
        attempts: Int,
        maxAttempts: Int = OfflineQueue.maxAttempts
    ) -> ReplayOutcome {
        if isServerUnreachable(error) { return .haltTransport }

        if let pgError = error as? PostgrestError {
            switch operation {
            case .create where pgError.code == "23505":
                // Duplicate key on the client-generated id — a previous
                // replay committed but the response was lost.
                return .treatAsSynced
            case .delete where pgError.code == "PGRST116":
                // Pre-delete row lookup found nothing — already deleted.
                return .treatAsSynced
            default:
                break
            }
        }

        return attempts + 1 >= maxAttempts ? .deadLetter : .retryCounted
    }

    /// The request never got a response: local timeout, DNS, TLS, dropped
    /// connection. The server may or may not have seen it.
    static func isTransportError(_ error: Error) -> Bool {
        if error is TimeoutError { return true }
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// The request got a response — but from the gateway in front of the
    /// database (Kong / Cloudflare), not from PostgREST or Postgres.
    ///
    /// During the 2026-09-10 Supabase outage ("Unresponsive Projects") every
    /// write came back `504 {"message":"Gateway Timeout"}`. The SDK decodes
    /// any JSON body with a `message` as `PostgrestError`, dropping the HTTP
    /// status, so the app saw an ordinary-looking database error, surfaced
    /// it, and the user's transaction was gone. A day of entries was lost
    /// while the app's own offline queue sat idle.
    ///
    /// Two shapes, both meaning "the database did not answer":
    /// - `HTTPError` with a gateway status (502 / 503 / 504, Cloudflare 52x)
    ///   — the body was not JSON.
    /// - `PostgrestError` with **no `code`**. PostgREST always sets one
    ///   (`PGRST…`) and so does Postgres (SQLSTATE); a bare `message` is the
    ///   gateway's own error envelope.
    static func isGatewayError(_ error: Error) -> Bool {
        if let http = error as? HTTPError {
            return gatewayStatusCodes.contains(http.response.statusCode)
        }
        if let pg = error as? PostgrestError {
            return pg.code == nil
        }
        return false
    }

    static let gatewayStatusCodes: Set<Int> = [502, 503, 504, 520, 521, 522, 523, 524]

    /// Either of the above — the operation is worth keeping and replaying,
    /// because nothing tells us the database rejected it.
    static func isServerUnreachable(_ error: Error) -> Bool {
        isTransportError(error) || isGatewayError(error)
    }

    /// The write MAY have committed even though we got no usable answer:
    /// a timeout at any layer (local, or the gateway giving up on
    /// PostgREST). Replaying a client-id create is still safe (23505 →
    /// synced), but an RPC create mints server-side ids we cannot predict,
    /// so its caller must not queue on these.
    static func mayHaveCommitted(_ error: Error) -> Bool {
        if error is TimeoutError { return true }
        if (error as? URLError)?.code == .timedOut { return true }
        if let http = error as? HTTPError {
            return [504, 522, 524].contains(http.response.statusCode)
        }
        // A codeless gateway message carries no status — assume the worst.
        if let pg = error as? PostgrestError { return pg.code == nil }
        return false
    }

    /// Whether a failed online create should fall back to the offline
    /// queue. Pure so the policy is unit-testable without a network.
    static func shouldQueueFailedCreate(_ error: Error, routesToAutoTransferRPC: Bool) -> Bool {
        guard isServerUnreachable(error) else { return false }
        if routesToAutoTransferRPC && mayHaveCommitted(error) { return false }
        return true
    }

    func processQueue() async {
        guard !isProcessing, !pendingOperations.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }

        let count = pendingOperations.count
        AppLogger.data.info("Offline queue: processing \(count) operations")

        // Iterate a snapshot of ids — `pendingOperations` can be mutated by
        // enqueue/coalesce while we're suspended in a network call.
        for opId in pendingOperations.map(\.id) {
            guard let op = pendingOperations.first(where: { $0.id == opId }) else { continue }
            do {
                try await replay(op)
                pendingOperations.removeAll { $0.id == opId }
                AppLogger.data.info("Offline queue: synced \(opId)")
            } catch {
                switch Self.outcome(for: error, operation: op.operation, attempts: op.attempts) {
                case .treatAsSynced:
                    pendingOperations.removeAll { $0.id == opId }
                    AppLogger.data.info("Offline queue: \(opId) already on server, dropping")
                case .haltTransport:
                    AppLogger.data.warning("Offline queue: transport error, halting round: \(error)")
                    save()
                    return
                case .retryCounted:
                    markFailed(opId, error: error)
                    AppLogger.data.warning("Offline queue: failed \(opId), will retry: \(error)")
                case .deadLetter:
                    if let failed = pendingOperations.first(where: { $0.id == opId }) {
                        var dead = failed
                        dead.attempts += 1
                        dead.lastErrorDescription = "\(error)"
                        deadLetterOperations.append(dead)
                        persistence.saveDeadLetterOps(deadLetterOperations)
                    }
                    pendingOperations.removeAll { $0.id == opId }
                    AppLogger.data.error("Offline queue: \(opId) dead-lettered after \(Self.maxAttempts) attempts: \(error)")
                }
            }
        }
        save()
    }

    private func replay(_ op: PendingOperation) async throws {
        switch op.operation {
        case .create(let input):
            _ = try await transactionRepo.create(input)
        case .update(let txId, let input):
            try await transactionRepo.update(id: txId, input)
        case .delete(let txId):
            try await transactionRepo.delete(id: txId)
        }
    }

    private func markFailed(_ opId: String, error: Error) {
        guard let idx = pendingOperations.firstIndex(where: { $0.id == opId }) else { return }
        pendingOperations[idx].attempts += 1
        pendingOperations[idx].lastErrorDescription = "\(error)"
    }

    private func save() {
        persistence.savePendingOps(pendingOperations)
    }
}
