import XCTest
import Supabase
@testable import AkifiIOS

/// Pins down `OfflineQueue.outcome(for:operation:attempts:)` — the replay
/// failure classifier. The invariants that matter:
///
/// - transport failures HALT the round (order preserved, no attempt burned)
/// - idempotency errors (23505 create / PGRST116 delete) resolve as synced
/// - anything else burns attempts and dead-letters at the cap so one
///   poisoned op can't block the queue forever
@MainActor
final class OfflineReplayClassificationTests: XCTestCase {

    private func createOp() -> PendingOperation.OperationType {
        .create(CreateTransactionInput(
            id: "tx-1", user_id: "u1", account_id: "acc-1",
            amount: 100, currency: "RUB", type: "expense", date: "2026-07-04",
            description: nil, category_id: nil, merchant_name: nil
        ))
    }

    private func deleteOp() -> PendingOperation.OperationType {
        .delete(transactionId: "tx-1")
    }

    private func updateOp() -> PendingOperation.OperationType {
        .update(transactionId: "tx-1", UpdateTransactionInput(description: "x"))
    }

    // MARK: - Idempotency

    func test_duplicateKeyOnCreate_treatsAsSynced() {
        let error = PostgrestError(code: "23505", message: "duplicate key value violates unique constraint")
        let outcome = OfflineQueue.outcome(for: error, operation: createOp(), attempts: 0)
        XCTAssertEqual(outcome, .treatAsSynced, "previous replay committed — drop, don't duplicate")
    }

    func test_missingRowOnDelete_treatsAsSynced() {
        let error = PostgrestError(code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned")
        let outcome = OfflineQueue.outcome(for: error, operation: deleteOp(), attempts: 0)
        XCTAssertEqual(outcome, .treatAsSynced, "row already gone — the delete's goal is achieved")
    }

    func test_duplicateKeyOnUpdate_isNotSpecialCased() {
        let error = PostgrestError(code: "23505", message: "duplicate key")
        let outcome = OfflineQueue.outcome(for: error, operation: updateOp(), attempts: 0)
        XCTAssertEqual(outcome, .retryCounted, "23505 shortcut applies to creates only")
    }

    // MARK: - Transport

    func test_urlError_haltsRound() {
        let outcome = OfflineQueue.outcome(
            for: URLError(.notConnectedToInternet),
            operation: createOp(),
            attempts: 0
        )
        XCTAssertEqual(outcome, .haltTransport)
    }

    func test_timeoutError_haltsRound() {
        let outcome = OfflineQueue.outcome(
            for: TimeoutError(seconds: 10),
            operation: updateOp(),
            attempts: 2
        )
        XCTAssertEqual(outcome, .haltTransport, "transport failures never burn attempts, even at the cap")
    }

    // MARK: - Permanent errors and the dead-letter cap

    func test_permanentError_belowCap_retryCounted() {
        let error = PostgrestError(code: "42501", message: "permission denied")
        XCTAssertEqual(OfflineQueue.outcome(for: error, operation: createOp(), attempts: 0), .retryCounted)
        XCTAssertEqual(OfflineQueue.outcome(for: error, operation: createOp(), attempts: 1), .retryCounted)
    }

    func test_permanentError_atCap_deadLetters() {
        let error = PostgrestError(code: "42501", message: "permission denied")
        let outcome = OfflineQueue.outcome(for: error, operation: createOp(), attempts: OfflineQueue.maxAttempts - 1)
        XCTAssertEqual(outcome, .deadLetter)
    }
}
