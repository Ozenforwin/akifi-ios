import XCTest
@testable import AkifiIOS

/// Pins down `OfflineQueue.coalesce(_:adding:)` — the pure function that
/// keeps the offline queue free of dependent-chain hazards:
///
/// 1. update-after-queued-create merges into the create (single INSERT replays
///    with final values; no UPDATE against a row that doesn't exist yet)
/// 2. delete-after-queued-create cancels the whole chain (nothing reaches the
///    server for a row that never synced)
/// 3. delete-after-updates-of-a-synced-row drops the now-obsolete updates
@MainActor
final class OfflineQueueCoalescingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeCreate(
        id: String = "tx-1",
        amount: Decimal = 100,
        description: String? = "Кофе",
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        fxRate: Decimal? = nil
    ) -> PendingOperation {
        PendingOperation(operation: .create(CreateTransactionInput(
            id: id,
            user_id: "u1",
            account_id: "acc-1",
            amount: amount,
            currency: "RUB",
            foreign_amount: foreignAmount,
            foreign_currency: foreignCurrency,
            fx_rate: fxRate,
            type: "expense",
            date: "2026-07-04",
            description: description,
            category_id: "cat-1",
            merchant_name: nil
        )))
    }

    private func makeUpdate(
        of txId: String,
        amount: Decimal? = nil,
        description: String? = nil,
        replaceCurrencyFields: Bool = false,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil
    ) -> PendingOperation {
        PendingOperation(operation: .update(transactionId: txId, UpdateTransactionInput(
            amount: amount,
            amount_native: amount,
            foreign_amount: foreignAmount,
            foreign_currency: foreignCurrency,
            description: description,
            replaceCurrencyFields: replaceCurrencyFields
        )))
    }

    private func makeDelete(of txId: String) -> PendingOperation {
        PendingOperation(operation: .delete(transactionId: txId))
    }

    private func createInput(_ op: PendingOperation) -> CreateTransactionInput? {
        if case .create(let input) = op.operation { return input }
        return nil
    }

    // MARK: - update-after-create

    func test_updateAfterQueuedCreate_mergesIntoCreate() {
        let queue = [makeCreate(id: "tx-1", amount: 100, description: "Кофе")]

        let result = OfflineQueue.coalesce(
            queue,
            adding: makeUpdate(of: "tx-1", amount: 250, description: "Обед")
        )

        XCTAssertEqual(result.count, 1, "update must merge, not append")
        let merged = createInput(result[0])
        XCTAssertNotNil(merged, "the surviving op must still be a create")
        XCTAssertEqual(merged?.id, "tx-1")
        XCTAssertEqual(merged?.amount, 250)
        XCTAssertEqual(merged?.description, "Обед")
        XCTAssertEqual(merged?.category_id, "cat-1", "untouched fields survive the merge")
    }

    func test_updateWithReplaceCurrencyFields_clearsForeignBlock() {
        let queue = [makeCreate(
            id: "tx-1", amount: 9_000,
            foreignAmount: 100, foreignCurrency: "USD", fxRate: 90
        )]

        // User switched the entry back to account currency: foreign block
        // must be wiped, not left at previous values.
        let result = OfflineQueue.coalesce(
            queue,
            adding: makeUpdate(of: "tx-1", amount: 8_500, replaceCurrencyFields: true)
        )

        let merged = createInput(result[0])
        XCTAssertEqual(merged?.amount, 8_500)
        XCTAssertNil(merged?.foreign_amount)
        XCTAssertNil(merged?.foreign_currency)
        XCTAssertNil(merged?.fx_rate)
    }

    func test_updateWithoutReplaceCurrencyFields_keepsForeignBlock() {
        let queue = [makeCreate(
            id: "tx-1", amount: 9_000,
            foreignAmount: 100, foreignCurrency: "USD", fxRate: 90
        )]

        let result = OfflineQueue.coalesce(
            queue,
            adding: makeUpdate(of: "tx-1", description: "Такси")
        )

        let merged = createInput(result[0])
        XCTAssertEqual(merged?.foreign_amount, 100, "patch-mode update must not clear foreign fields")
        XCTAssertEqual(merged?.foreign_currency, "USD")
    }

    func test_updateOfSyncedRow_appendsFIFO() {
        let queue = [makeCreate(id: "tx-1")]

        let result = OfflineQueue.coalesce(
            queue,
            adding: makeUpdate(of: "tx-synced", description: "Новый текст")
        )

        XCTAssertEqual(result.count, 2, "update of a row not in the queue appends in order")
        if case .update(let txId, _) = result[1].operation {
            XCTAssertEqual(txId, "tx-synced")
        } else {
            XCTFail("appended op must be the update")
        }
    }

    // MARK: - delete-after-create

    func test_deleteAfterQueuedCreate_cancelsWholeChain() {
        var queue = [makeCreate(id: "tx-1"), makeCreate(id: "tx-2")]
        queue = OfflineQueue.coalesce(queue, adding: makeUpdate(of: "tx-1", amount: 500))

        let result = OfflineQueue.coalesce(queue, adding: makeDelete(of: "tx-1"))

        XCTAssertEqual(result.count, 1, "create+updates of tx-1 cancel; delete is NOT enqueued")
        XCTAssertEqual(createInput(result[0])?.id, "tx-2", "unrelated op survives")
    }

    func test_deleteOfSyncedRow_dropsItsUpdates_keepsDelete() {
        var queue: [PendingOperation] = []
        queue = OfflineQueue.coalesce(queue, adding: makeUpdate(of: "tx-synced", amount: 500))
        queue = OfflineQueue.coalesce(queue, adding: makeCreate(id: "tx-other"))

        let result = OfflineQueue.coalesce(queue, adding: makeDelete(of: "tx-synced"))

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(createInput(result[0])?.id, "tx-other", "unrelated create survives, order preserved")
        if case .delete(let txId) = result[1].operation {
            XCTAssertEqual(txId, "tx-synced")
        } else {
            XCTFail("delete must be appended last")
        }
    }

    // MARK: - ordering

    func test_unrelatedOps_preserveFIFOOrder() {
        var queue: [PendingOperation] = []
        queue = OfflineQueue.coalesce(queue, adding: makeCreate(id: "tx-1"))
        queue = OfflineQueue.coalesce(queue, adding: makeUpdate(of: "tx-synced", amount: 10))
        queue = OfflineQueue.coalesce(queue, adding: makeCreate(id: "tx-2"))

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue[0].targetTransactionId, "tx-1")
        XCTAssertEqual(queue[1].targetTransactionId, "tx-synced")
        XCTAssertEqual(queue[2].targetTransactionId, "tx-2")
    }
}
