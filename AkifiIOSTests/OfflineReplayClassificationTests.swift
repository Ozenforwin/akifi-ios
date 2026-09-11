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

    // MARK: - Gateway errors (2026-09-10 Supabase outage)

    /// What the app actually received on 2026-09-10: Kong's 504 envelope,
    /// decoded by the SDK as a PostgrestError with no code. Must halt the
    /// round like a dropped connection, not burn attempts.
    func test_gatewayTimeoutAsCodelessPostgrestError_haltsRound() {
        let error = PostgrestError(message: "Gateway Timeout")
        XCTAssertTrue(OfflineQueue.isGatewayError(error))
        let outcome = OfflineQueue.outcome(for: error, operation: createOp(), attempts: 2)
        XCTAssertEqual(outcome, .haltTransport, "the database never answered — keep the op, wait for it to come back")
    }

    func test_gatewayStatusAsHTTPError_haltsRound() {
        for status in [502, 503, 504, 520, 522, 524] {
            let error = httpError(status: status)
            XCTAssertTrue(OfflineQueue.isGatewayError(error), "status \(status)")
            XCTAssertEqual(
                OfflineQueue.outcome(for: error, operation: updateOp(), attempts: 2),
                .haltTransport, "status \(status)"
            )
        }
    }

    /// A real database error always carries a code. It must keep burning
    /// attempts — otherwise a poisoned op would block the queue forever
    /// under the new rule.
    func test_codedPostgrestError_isNotGateway() {
        let error = PostgrestError(code: "42501", message: "permission denied for table transactions")
        XCTAssertFalse(OfflineQueue.isGatewayError(error))
        XCTAssertEqual(OfflineQueue.outcome(for: error, operation: createOp(), attempts: 0), .retryCounted)
    }

    func test_clientErrorStatus_isNotGateway() {
        for status in [400, 401, 403, 404, 409, 500] {
            XCTAssertFalse(OfflineQueue.isGatewayError(httpError(status: status)), "status \(status)")
        }
    }

    // MARK: - Create fallback policy

    /// Plain creates carry a client-generated id, so a replay after a
    /// possible server-side commit resolves as 23505 → synced. Queue on
    /// every "no answer" error, gateway included.
    func test_plainCreate_queuesOnAnyUnreachable() {
        let errors: [Error] = [
            URLError(.networkConnectionLost),
            TimeoutError(seconds: 10),
            PostgrestError(message: "Gateway Timeout"),
            httpError(status: 503),
            httpError(status: 504),
        ]
        for error in errors {
            XCTAssertTrue(
                OfflineQueue.shouldQueueFailedCreate(error, routesToAutoTransferRPC: false),
                "\(error)"
            )
        }
    }

    /// The RPC triplet create mints server-side ids: if the write may have
    /// committed, replaying duplicates it. Surface timeouts at any layer;
    /// still queue when the server was definitely not reached.
    func test_rpcCreate_surfacesWhenWriteMayHaveCommitted() {
        XCTAssertFalse(OfflineQueue.shouldQueueFailedCreate(TimeoutError(seconds: 10), routesToAutoTransferRPC: true))
        XCTAssertFalse(OfflineQueue.shouldQueueFailedCreate(URLError(.timedOut), routesToAutoTransferRPC: true))
        XCTAssertFalse(OfflineQueue.shouldQueueFailedCreate(httpError(status: 504), routesToAutoTransferRPC: true))
        XCTAssertFalse(OfflineQueue.shouldQueueFailedCreate(PostgrestError(message: "Gateway Timeout"), routesToAutoTransferRPC: true),
                       "no status on a codeless envelope — assume it may have committed")

        XCTAssertTrue(OfflineQueue.shouldQueueFailedCreate(URLError(.notConnectedToInternet), routesToAutoTransferRPC: true))
        XCTAssertTrue(OfflineQueue.shouldQueueFailedCreate(httpError(status: 503), routesToAutoTransferRPC: true),
                      "503 = upstream unavailable, the request was never processed")
    }

    /// A database rejection is never queued — it would fail again the same
    /// way, and the user needs to see it now.
    func test_databaseError_isSurfacedNotQueued() {
        let error = PostgrestError(code: "23514", message: "new row violates check constraint")
        XCTAssertFalse(OfflineQueue.shouldQueueFailedCreate(error, routesToAutoTransferRPC: false))
    }

    // MARK: - Helpers

    private func httpError(status: Int) -> HTTPError {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.supabase.co/rest/v1/transactions")!,
            statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return HTTPError(data: Data("<html>error</html>".utf8), response: response)
    }

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
