import Foundation
import Supabase
import os

struct PendingOperation: Codable, Sendable, Identifiable {
    let id: String
    let timestamp: Date
    let operation: OperationType
    /// Replay attempts that failed with a permanent-looking error, counted
    /// at most once per `OfflineQueue.attemptWindow`. Transport / transient
    /// server failures don't count — they halt the round instead.
    var attempts: Int
    var lastErrorDescription: String?
    /// When the last *counted* attempt happened. A burst of replays (every
    /// form save triggers one) must not burn all attempts in seconds.
    var lastAttemptAt: Date?
    /// Set on a create once a request carrying it may have reached the
    /// server (a replay started, or an online create died without an
    /// answer). Such a create can no longer be cancelled or rewritten
    /// locally: the server may already hold the row, so later edits and
    /// deletes are appended behind it instead of folded into it.
    var mayExistOnServer: Bool
    /// A create that later offline edits were folded into (Y4). If its
    /// replay hits 23505 the row is already on the server — but possibly
    /// with the values from before the edits, so the folded fields are
    /// replayed as an UPDATE instead of being dropped as "synced".
    var hasFoldedUpdates: Bool

    enum OperationType: Codable, Sendable {
        case create(CreateTransactionInput)
        case update(transactionId: String, UpdateTransactionInput)
        case delete(transactionId: String)
        /// Both legs of a manual transfer (Y8): one DELETE by
        /// `transfer_group_id`. `transactionIds` are the legs this op
        /// orders behind (their queued creates replay first).
        case deleteTransferGroup(groupId: String, transactionIds: [String])
    }

    init(operation: OperationType, mayExistOnServer: Bool = false) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.operation = operation
        self.attempts = 0
        self.lastErrorDescription = nil
        self.lastAttemptAt = nil
        self.mayExistOnServer = mayExistOnServer
        self.hasFoldedUpdates = false
    }

    /// Copy with a replaced operation, preserving identity/ordering metadata.
    /// Used when coalescing folds an update into a queued create.
    init(recreating original: PendingOperation, operation: OperationType) {
        self.id = original.id
        self.timestamp = original.timestamp
        self.operation = operation
        self.attempts = original.attempts
        self.lastErrorDescription = original.lastErrorDescription
        self.lastAttemptAt = original.lastAttemptAt
        self.mayExistOnServer = original.mayExistOnServer
        self.hasFoldedUpdates = original.hasFoldedUpdates
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, operation, attempts, lastErrorDescription, lastAttemptAt, mayExistOnServer
        case hasFoldedUpdates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        operation = try c.decode(OperationType.self, forKey: .operation)
        // Tolerant decode: queue files written by older builds lack these.
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastErrorDescription = try c.decodeIfPresent(String.self, forKey: .lastErrorDescription)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        mayExistOnServer = try c.decodeIfPresent(Bool.self, forKey: .mayExistOnServer) ?? false
        hasFoldedUpdates = try c.decodeIfPresent(Bool.self, forKey: .hasFoldedUpdates) ?? false
    }

    /// The transaction this operation targets (client id for creates); nil
    /// for an op on several rows (`deleteTransferGroup`).
    var targetTransactionId: String? {
        switch operation {
        case .create(let input): return input.id
        case .update(let txId, _): return txId
        case .delete(let txId): return txId
        case .deleteTransferGroup: return nil
        }
    }

    /// Every transaction this operation touches — the ordering key of the
    /// replay (an op never overtakes an earlier op on one of its rows).
    var targetTransactionIds: [String] {
        if case .deleteTransferGroup(_, let ids) = operation { return ids }
        return targetTransactionId.map { [$0] } ?? []
    }

    var isCreate: Bool {
        if case .create = operation { return true }
        return false
    }
}

@Observable @MainActor
final class OfflineQueue {
    private(set) var pendingOperations: [PendingOperation] = []
    /// Operations that failed `maxAttempts` times with a permanent error.
    /// Kept out of the replay path so one poisoned op can't block the queue;
    /// surfaced in Settings for the user to retry or discard.
    private(set) var deadLetterOperations: [PendingOperation] = []
    /// True while a replay round is in flight — guards against `loadAll()`
    /// racing the reconnect hook into double-replaying the same op.
    private(set) var isProcessing = false
    /// The op whose request is on the wire right now. Coalescing never
    /// folds into it — the server is about to (or already did) apply the
    /// version that was sent.
    private(set) var inFlightOperationId: String?
    /// User the queued ops belong to. Replay only runs under that user's
    /// session; a different user signing in discards them.
    private(set) var ownerUserId: String?

    private let persistence: PersistenceManager

    /// Replays one op against the server. Seam for tests.
    @ObservationIgnored var replayOperation: @MainActor (PendingOperation) async throws -> Void = { op in
        try await OfflineQueue.liveReplay(op)
    }
    /// Id of the user whose session is valid right now, or nil when there is
    /// none (refresh failed, signed out). Without a session the SDK sends
    /// the anon key: inserts fail RLS and updates/deletes match zero rows
    /// and "succeed" — the queue would drain into nothing.
    @ObservationIgnored var sessionUserIdProvider: @MainActor () async -> String? = {
        await SupabaseManager.shared.validSessionUserId()
    }
    /// Synchronous best guess of the signed-in user, used to tag the queue
    /// owner at enqueue time.
    @ObservationIgnored var currentUserIdProvider: @MainActor () -> String? = {
        SupabaseManager.shared.client.auth.currentSession?.user.id.uuidString.lowercased()
    }
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    static let maxAttempts = 3
    /// At most one counted attempt per op per window (see `attempts`).
    static let attemptWindow: TimeInterval = 5 * 60

    var hasPending: Bool { !pendingOperations.isEmpty }
    var pendingCount: Int { pendingOperations.count }

    init(persistence: PersistenceManager = .shared) {
        self.persistence = persistence
        pendingOperations = persistence.loadPendingOps() ?? []
        deadLetterOperations = persistence.loadDeadLetterOps() ?? []
        ownerUserId = persistence.loadQueueOwner()
    }

    func enqueue(_ op: PendingOperation) {
        if ownerUserId == nil, let uid = currentUserIdProvider() {
            setOwner(uid)
        }
        pendingOperations = Self.coalesce(pendingOperations, adding: op, inFlightId: inFlightOperationId)
        save()
        AppLogger.data.info("Offline queue: enqueued \(op.id), depth \(self.pendingOperations.count)")
    }

    /// True when the queue still holds the CREATE for this transaction —
    /// i.e. the row exists only locally (or its sync is in flight).
    func hasQueuedCreate(for transactionId: String) -> Bool {
        pendingOperations.contains { Self.isCreate($0, of: transactionId) }
    }

    /// True when any queued op targets this transaction. A direct online
    /// write to such a row would race the queue: the queued op replays
    /// later and overwrites it with older values (or the UPDATE hits a row
    /// whose INSERT hasn't replayed yet and silently matches nothing).
    func hasPendingOperations(for transactionId: String) -> Bool {
        pendingOperations.contains { $0.targetTransactionIds.contains(transactionId) }
    }

    /// Queued plus dead-lettered — everything this device holds that the
    /// server doesn't have. Sign-out wipes all of it, so its warning counts
    /// both (Y6).
    var unsyncedCount: Int { pendingOperations.count + deadLetterOperations.count }
    var hasUnsynced: Bool { unsyncedCount > 0 }

    /// Called with the ops a replay round just moved to dead letters, so the
    /// store can raise a banner and mark their rows "не сохранено" (Y6).
    @ObservationIgnored var onDeadLettered: (@MainActor ([PendingOperation]) -> Void)?

    func discardDeadLetters() {
        deadLetterOperations = []
        persistence.saveDeadLetterOps(deadLetterOperations)
    }

    /// "Повторить" in Settings: dead letters go back into the replay path
    /// with a fresh attempt budget, in their original order.
    func retryDeadLetters() {
        guard !deadLetterOperations.isEmpty else { return }
        let revived = deadLetterOperations.map { op -> PendingOperation in
            var copy = op
            copy.attempts = 0
            copy.lastAttemptAt = nil
            return copy
        }
        deadLetterOperations = []
        pendingOperations = (revived + pendingOperations).sorted { $0.timestamp < $1.timestamp }
        persistence.saveDeadLetterOps(deadLetterOperations)
        save()
    }

    /// A different user signed in: queued ops of the previous user must
    /// neither replay under the new session nor show up in its overlay.
    func adoptOwner(_ userId: String) {
        if let owner = ownerUserId, owner != userId {
            AppLogger.data.warning("Offline queue: dropping \(self.pendingOperations.count) ops of a previous user")
            pendingOperations = []
            deadLetterOperations = []
            save()
            persistence.saveDeadLetterOps(deadLetterOperations)
        }
        setOwner(userId)
    }

    /// Sign-out: forget everything (the persistence layer wipes the files).
    func reset() {
        pendingOperations = []
        deadLetterOperations = []
        ownerUserId = nil
        inFlightOperationId = nil
        save()
        persistence.saveDeadLetterOps(deadLetterOperations)
        persistence.saveQueueOwner(nil)
    }

    private func setOwner(_ userId: String) {
        guard ownerUserId != userId else { return }
        ownerUserId = userId
        persistence.saveQueueOwner(userId)
    }

    // MARK: - Coalescing

    /// Folds the incoming op into the queue so dependent chains collapse:
    /// - update of a queued create → merged into the create's payload
    /// - delete of a queued create → create (and its updates) removed,
    ///   nothing reaches the server
    /// - delete of a synced row → queued updates of that row dropped as
    ///   obsolete, delete appended
    ///
    /// A create that is in flight (`inFlightId`) or may already exist on
    /// the server (`mayExistOnServer`) is treated like a synced row: the
    /// request that reached the server can't be rewritten, so the update /
    /// delete is appended behind it and replays after it.
    /// Pure and static for unit testing.
    static func coalesce(
        _ queue: [PendingOperation],
        adding op: PendingOperation,
        inFlightId: String? = nil
    ) -> [PendingOperation] {
        func isFoldable(_ candidate: PendingOperation) -> Bool {
            candidate.id != inFlightId && !candidate.mayExistOnServer
        }

        switch op.operation {
        case .create:
            return queue + [op]

        case .update(let txId, let update):
            if let idx = queue.firstIndex(where: { isCreate($0, of: txId) }),
               isFoldable(queue[idx]),
               case .create(let input) = queue[idx].operation {
                var merged = queue
                var folded = PendingOperation(
                    recreating: queue[idx],
                    operation: .create(input.applying(update))
                )
                folded.hasFoldedUpdates = true
                merged[idx] = folded
                return merged
            }
            return queue + [op]

        case .delete(let txId):
            if let create = queue.first(where: { isCreate($0, of: txId) }), isFoldable(create) {
                // The row never reached the server — cancel everything.
                return queue.filter { $0.targetTransactionId != txId }
            }
            // Synced (or possibly synced) row: queued updates are obsolete,
            // except one already on the wire.
            return queue.filter { !isUpdate($0, of: txId) || $0.id == inFlightId } + [op]

        case .deleteTransferGroup(let groupId, let legIds):
            // Per leg, like `.delete`: a leg whose create never left the
            // device is cancelled outright; a leg that is (or may be) on the
            // server needs the DELETE — which removes the whole group there.
            var result = queue
            var serverLegs: [String] = []
            for txId in legIds {
                if let create = result.first(where: { isCreate($0, of: txId) }), isFoldable(create) {
                    result = result.filter { !$0.targetTransactionIds.contains(txId) }
                } else {
                    result = result.filter { !isUpdate($0, of: txId) || $0.id == inFlightId }
                    serverLegs.append(txId)
                }
            }
            guard !serverLegs.isEmpty else { return result }
            return result + [PendingOperation(
                recreating: op,
                operation: .deleteTransferGroup(groupId: groupId, transactionIds: serverLegs)
            )]
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

    // MARK: - Replay classification

    enum ReplayOutcome: Equatable {
        /// The server already has this state (duplicate create / missing
        /// row on delete) — drop the op as synced.
        case treatAsSynced
        /// Duplicate create whose payload carries folded offline edits (Y4):
        /// the row is there, the edits may not be — replay them as UPDATE.
        case replayAsUpdate
        /// Transport-level or transient server failure — stop the round,
        /// keep ALL remaining ops in order so dependent chains never replay
        /// out of order. No attempt is burned.
        case haltTransport
        /// Permanent-looking error, attempts left — keep for the next round.
        case retryCounted
        /// Permanent-looking error again within `attemptWindow` of the last
        /// counted one — keep, don't burn another attempt.
        case retryUncounted
        /// Failed `maxAttempts` times — move to the dead-letter list.
        case deadLetter
    }

    /// Classifies a replay failure. Pure and static for unit testing.
    static func outcome(
        for error: Error,
        operation: PendingOperation.OperationType,
        attempts: Int,
        lastAttemptAt: Date? = nil,
        now: Date = Date(),
        maxAttempts: Int = OfflineQueue.maxAttempts,
        hasFoldedUpdates: Bool = false
    ) -> ReplayOutcome {
        if isServerUnreachable(error) || isTransientServerError(error) { return .haltTransport }

        if let pgError = error as? PostgrestError {
            switch operation {
            case .create where pgError.code == "23505":
                // Duplicate key on the client-generated id (plain INSERT, or
                // `p_id` of the auto-transfer RPC) — a previous request
                // committed but the response was lost. Edits folded in after
                // that request went out are not on the server yet.
                return hasFoldedUpdates ? .replayAsUpdate : .treatAsSynced
            case .delete where pgError.code == "PGRST116":
                // Pre-delete row lookup found nothing — already deleted.
                return .treatAsSynced
            default:
                break
            }
        }

        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < attemptWindow {
            return .retryUncounted
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

    /// Errors the database (or PostgREST in front of it) returns while it
    /// is overloaded or briefly unavailable — the request was well-formed
    /// and will succeed later. Treating them as permanent sent the whole
    /// queue to dead-letter after three saves during an incident.
    /// - PGRST000–003: PostgREST can't reach / lost / timed out waiting for
    ///   a database connection, schema cache not loaded yet
    /// - 57014 statement timeout · 40001 serialization failure ·
    ///   53300 too many connections
    /// - PGRST301: the JWT was rejected (expired mid-flight) — the next
    ///   round runs after a session refresh
    static let transientPostgrestCodes: Set<String> = [
        "PGRST000", "PGRST001", "PGRST002", "PGRST003",
        "57014", "40001", "53300",
        "PGRST301",
    ]

    static func isTransientServerError(_ error: Error) -> Bool {
        if let pg = error as? PostgrestError, let code = pg.code {
            return transientPostgrestCodes.contains(code)
        }
        return false
    }

    /// Either of the above — the operation is worth keeping and replaying,
    /// because nothing tells us the database rejected it.
    static func isServerUnreachable(_ error: Error) -> Bool {
        isTransportError(error) || isGatewayError(error)
    }

    /// A failed online write should go to the queue instead of surfacing:
    /// the database never answered, or answered "try again later".
    static func shouldQueueFailedWrite(_ error: Error) -> Bool {
        isServerUnreachable(error) || isTransientServerError(error)
    }

    /// The write MAY have committed even though we got no usable answer (Y4).
    ///
    /// Only an error that provably happened before the request left the
    /// device (no route, DNS, TCP connect, TLS handshake) means "not sent".
    /// Everything else — a timeout, a connection dropped mid-response
    /// (`networkConnectionLost`), any gateway status — may have reached the
    /// database with the answer lost on the way back. Treating those as
    /// "not sent" let a later offline edit fold into the create; the replay
    /// then hit 23505, counted as synced, and the edit was gone.
    static func mayHaveCommitted(_ error: Error) -> Bool {
        if error is TimeoutError { return true }
        if let code = urlErrorCode(error) { return !preSendURLErrorCodes.contains(code) }
        if let http = error as? HTTPError {
            return gatewayStatusCodes.contains(http.response.statusCode)
        }
        // A codeless gateway message carries no status — assume the worst.
        if let pg = error as? PostgrestError { return pg.code == nil || pg.code == "57014" }
        return false
    }

    /// Transport failures that happen before a byte of the request is sent:
    /// there is no connection to send it over yet.
    static let preSendURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
    ]

    private static func urlErrorCode(_ error: Error) -> URLError.Code? {
        if let url = error as? URLError { return url.code }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? URLError.Code(rawValue: ns.code) : nil
    }

    /// Whether a failed online create should fall back to the offline
    /// queue. Pure so the policy is unit-testable without a network.
    ///
    /// Every create carries a client id — the plain INSERT as `id`, the
    /// auto-transfer RPC as `p_id` — so a replay of a create that did commit
    /// fails with 23505 and resolves as synced. Only an RPC create without
    /// a client id (a caller that bypassed `withClientId()`) is unsafe to
    /// replay when the write may have committed.
    static func shouldQueueFailedCreate(
        _ error: Error,
        routesToAutoTransferRPC: Bool,
        hasClientId: Bool = true
    ) -> Bool {
        guard shouldQueueFailedWrite(error) else { return false }
        if routesToAutoTransferRPC && !hasClientId && mayHaveCommitted(error) { return false }
        return true
    }

    // MARK: - Replay

    func processQueue() async {
        guard !isProcessing, !pendingOperations.isEmpty else { return }
        isProcessing = true
        defer {
            isProcessing = false
            inFlightOperationId = nil
        }

        // No session = offline. Replaying as anon would "succeed" into
        // nothing (see `sessionUserIdProvider`).
        guard let sessionUser = await sessionUserIdProvider() else {
            AppLogger.data.info("Offline queue: no valid session, replay postponed")
            return
        }
        if let owner = ownerUserId, owner != sessionUser {
            AppLogger.data.warning("Offline queue: ops belong to another user, not replaying")
            return
        }
        if ownerUserId == nil { setOwner(sessionUser) }

        AppLogger.data.info("Offline queue: processing \(self.pendingOperations.count) operations")

        // Walk the live array, not a snapshot: ops enqueued while a request
        // is in flight (an edit of the row being created) replay in the
        // same round, after the op they depend on. Each op runs at most
        // once per round; a failed op blocks later ops of the same
        // transaction so they never overtake it.
        var attempted: Set<String> = []
        var blockedTargets: Set<String> = []
        var deadLettered: [PendingOperation] = []
        defer {
            if !deadLettered.isEmpty { onDeadLettered?(deadLettered) }
        }
        while let op = pendingOperations.first(where: { candidate in
            !attempted.contains(candidate.id)
                && candidate.targetTransactionIds.allSatisfy { !blockedTargets.contains($0) }
        }) {
            // Y5: the session is re-validated before EVERY op, not once per
            // round. A token that expired mid-round with a failed refresh
            // makes the SDK send the anon key: the UPDATE matches nothing
            // and "succeeds", the DELETE's lookup finds nothing and counts
            // as done. Stop instead; the next round runs after a refresh.
            if !attempted.isEmpty {
                guard await sessionUserIdProvider() == sessionUser else {
                    AppLogger.data.warning("Offline queue: session expired or changed mid-round, halting")
                    save()
                    return
                }
            }
            let opId = op.id
            attempted.insert(opId)
            if op.isCreate { markMayExistOnServer(opId, true) }
            inFlightOperationId = opId
            save()

            do {
                try await replayOperation(op)
                inFlightOperationId = nil
                pendingOperations.removeAll { $0.id == opId }
                AppLogger.data.info("Offline queue: synced \(opId)")
            } catch {
                inFlightOperationId = nil
                let current = pendingOperations.first { $0.id == opId } ?? op
                let outcome = Self.outcome(
                    for: error, operation: current.operation,
                    attempts: current.attempts, lastAttemptAt: current.lastAttemptAt, now: now(),
                    hasFoldedUpdates: current.hasFoldedUpdates
                )
                switch outcome {
                case .treatAsSynced:
                    pendingOperations.removeAll { $0.id == opId }
                    AppLogger.data.info("Offline queue: \(opId) already on server, dropping")
                case .replayAsUpdate:
                    // The row exists; send the final field values as an
                    // UPDATE in this same round (same position in the queue,
                    // so later ops of the row still wait for it).
                    if case .create(let input) = current.operation, let txId = input.id,
                       let idx = pendingOperations.firstIndex(where: { $0.id == opId }) {
                        var asUpdate = PendingOperation(
                            recreating: current,
                            operation: .update(transactionId: txId, UpdateTransactionInput(replaying: input))
                        )
                        asUpdate.hasFoldedUpdates = false
                        asUpdate.mayExistOnServer = false
                        pendingOperations[idx] = asUpdate
                        attempted.remove(opId)
                        AppLogger.data.info("Offline queue: \(opId) already created, replaying its edits as update")
                    } else {
                        pendingOperations.removeAll { $0.id == opId }
                    }
                case .haltTransport:
                    AppLogger.data.warning("Offline queue: server unavailable, halting round: \(error)")
                    save()
                    return
                case .retryCounted, .retryUncounted:
                    markFailed(opId, error: error, counted: outcome == .retryCounted)
                    // A plain INSERT is one request: a coded rejection means
                    // it did not commit, so it may be folded into again. The
                    // RPC create is two requests (call + re-fetch) — a coded
                    // error may come from the re-fetch after a commit.
                    if case .create(let input) = current.operation,
                       !input.routesToAutoTransferRPC,
                       (error as? PostgrestError)?.code != nil {
                        markMayExistOnServer(opId, false)
                    }
                    blockedTargets.formUnion(current.targetTransactionIds)
                    AppLogger.data.warning("Offline queue: failed \(opId), will retry: \(error)")
                case .deadLetter:
                    deadLettered += deadLetter(opId, error: error)
                    blockedTargets.formUnion(current.targetTransactionIds)
                    AppLogger.data.error("Offline queue: \(opId) dead-lettered after \(Self.maxAttempts) attempts: \(error)")
                }
            }
        }
        save()
    }

    /// Moves the op to dead letters — together with every later op on one
    /// of its transactions, which can only fail (or silently match nothing)
    /// without it. "Повторить" brings the chain back in order. Returns the
    /// moved ops.
    @discardableResult
    private func deadLetter(_ opId: String, error: Error) -> [PendingOperation] {
        guard let idx = pendingOperations.firstIndex(where: { $0.id == opId }) else { return [] }
        var dead = pendingOperations[idx]
        dead.attempts += 1
        dead.lastAttemptAt = now()
        dead.lastErrorDescription = "\(error)"
        var moved = [dead]
        var targets = Set(dead.targetTransactionIds)
        for later in pendingOperations[(idx + 1)...] where !targets.isDisjoint(with: later.targetTransactionIds) {
            moved.append(later)
            targets.formUnion(later.targetTransactionIds)
        }
        let movedIds = Set(moved.map(\.id))
        pendingOperations.removeAll { movedIds.contains($0.id) }
        deadLetterOperations.append(contentsOf: moved)
        persistence.saveDeadLetterOps(deadLetterOperations)
        return moved
    }

    private static func liveReplay(_ op: PendingOperation) async throws {
        let repo = TransactionRepository()
        switch op.operation {
        case .create(let input):
            _ = try await repo.create(input)
        case .update(let txId, let input):
            try await repo.update(id: txId, input)
        case .delete(let txId):
            try await repo.delete(id: txId)
        case .deleteTransferGroup(let groupId, _):
            try await repo.deleteTransferGroup(groupId: groupId)
        }
    }

    private func markFailed(_ opId: String, error: Error, counted: Bool) {
        guard let idx = pendingOperations.firstIndex(where: { $0.id == opId }) else { return }
        if counted {
            pendingOperations[idx].attempts += 1
            pendingOperations[idx].lastAttemptAt = now()
        }
        pendingOperations[idx].lastErrorDescription = "\(error)"
    }

    private func markMayExistOnServer(_ opId: String, _ value: Bool) {
        guard let idx = pendingOperations.firstIndex(where: { $0.id == opId }),
              pendingOperations[idx].mayExistOnServer != value else { return }
        pendingOperations[idx].mayExistOnServer = value
    }

    private func save() {
        persistence.savePendingOps(pendingOperations)
    }
}
