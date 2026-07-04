import XCTest
@testable import AkifiIOS

/// End-to-end offline mutation paths through `DataStore` with an injected
/// temp-dir `PersistenceManager` and `isConnectedProvider = { false }` —
/// no network is touched because every offline branch returns before the
/// repository call.
@MainActor
final class DataStoreOfflineTests: XCTestCase {

    private var tempDir: URL!
    private var persistence: PersistenceManager!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineTests-\(UUID().uuidString)", isDirectory: true)
        persistence = PersistenceManager(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private let rates: [String: Double] = ["USD": 1.0, "RUB": 100.0]

    private func makeAccount(id: String, name: String, initialBalance: Int64 = 100_000_00) -> Account {
        Account(
            id: id, userId: "u1", name: name, icon: "💳", color: "#3B82F6",
            initialBalance: initialBalance, currency: "RUB"
        )
    }

    private func makeOfflineStore(accounts: [Account]) -> DataStore {
        let store = DataStore(cache: persistence)
        store.isConnectedProvider = { false }
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = rates
        store.currencyManager = cm
        store.accounts = accounts
        store.rebuildCaches()
        return store
    }

    private func makeCreateInput(
        id: String? = nil,
        accountId: String = "acc-1",
        amount: Decimal = 500,
        type: String = "expense",
        transferGroupId: String? = nil,
        paymentSourceAccountId: String? = nil,
        sourceAmount: Decimal? = nil,
        sourceCurrency: String? = nil,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        fxRate: Decimal? = nil
    ) -> CreateTransactionInput {
        CreateTransactionInput(
            id: id,
            user_id: "u1",
            account_id: accountId,
            amount: amount,
            currency: "RUB",
            foreign_amount: foreignAmount,
            foreign_currency: foreignCurrency,
            fx_rate: fxRate,
            type: type,
            date: "2026-07-04",
            description: "Тест",
            category_id: "cat-1",
            merchant_name: "Магазин",
            transfer_group_id: transferGroupId,
            payment_source_account_id: paymentSourceAccountId,
            source_amount: sourceAmount,
            source_currency: sourceCurrency
        )
    }

    // MARK: - Offline create

    func test_offlineCreate_insertsFullFidelityPlaceholder() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])

        let tx = try await store.addTransaction(makeCreateInput(
            amount: 1_900,
            foreignAmount: 500_000, foreignCurrency: "VND", fxRate: Decimal(string: "0.0038")!
        ))

        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertEqual(tx.status, "pending")
        XCTAssertEqual(tx.amountNative, 1_900_00, "amount_native lands in kopecks, not amount*100 of foreign")
        XCTAssertEqual(tx.foreignAmount, 500_000, "foreign entry fields survive into the placeholder")
        XCTAssertEqual(tx.foreignCurrency, "VND")
        XCTAssertEqual(tx.merchantName, "Магазин")
        XCTAssertEqual(store.offlineQueue.pendingCount, 1)

        // Balance: 100 000 ₽ initial − 1 900 ₽ = 98 100 ₽ (RUB base, identity FX)
        XCTAssertEqual(store.balance(for: store.accounts[0]), 98_100_00)
    }

    func test_offlineCreate_persistsPlaceholderToCache() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])

        _ = try await store.addTransaction(makeCreateInput())

        // Simulate app kill + relaunch offline: a fresh store over the same
        // cache directory must resurrect the placeholder.
        let cached = persistence.loadTransactions()
        XCTAssertEqual(cached?.count, 1, "placeholder must survive an app kill while offline")
        XCTAssertEqual(cached?.first?.status, "pending")
    }

    // MARK: - Offline transfer (two legs)

    func test_offlineTransfer_movesBothBalances() async throws {
        let from = makeAccount(id: "acc-from", name: "Карта")
        let to = makeAccount(id: "acc-to", name: "Наличные")
        let store = makeOfflineStore(accounts: [from, to])
        let groupId = UUID().uuidString

        _ = try await store.addTransaction(makeCreateInput(
            accountId: "acc-from", amount: 5_000, type: "expense", transferGroupId: groupId
        ))
        _ = try await store.addTransaction(makeCreateInput(
            accountId: "acc-to", amount: 5_000, type: "income", transferGroupId: groupId
        ))

        XCTAssertEqual(store.offlineQueue.pendingCount, 2)
        XCTAssertEqual(store.balance(for: from), 95_000_00)
        XCTAssertEqual(store.balance(for: to), 105_000_00)
    }

    // MARK: - Offline payment-source expense (auto-transfer triplet)

    func test_offlinePaymentSourceExpense_synthesizesTriplet() async throws {
        let target = makeAccount(id: "acc-shared", name: "Семейный")
        let source = makeAccount(id: "acc-personal", name: "Личный")
        let store = makeOfflineStore(accounts: [target, source])

        let tx = try await store.addTransaction(makeCreateInput(
            accountId: "acc-shared", amount: 3_000,
            paymentSourceAccountId: "acc-personal"
        ))

        XCTAssertEqual(store.transactions.count, 3, "expense + two transfer legs")
        XCTAssertEqual(tx.status, "pending")
        XCTAssertNotNil(tx.autoTransferGroupId)
        XCTAssertEqual(store.offlineQueue.pendingCount, 1, "one queued op — the RPC creates the triplet server-side")

        // Target nets zero (expense −3000, transfer-in +3000); source pays.
        XCTAssertEqual(store.balance(for: target), 100_000_00)
        XCTAssertEqual(store.balance(for: source), 97_000_00)
    }

    func test_editingPendingAutoTransferOffline_isBlocked() async throws {
        let store = makeOfflineStore(accounts: [
            makeAccount(id: "acc-shared", name: "Семейный"),
            makeAccount(id: "acc-personal", name: "Личный")
        ])
        let tx = try await store.addTransaction(makeCreateInput(
            accountId: "acc-shared", amount: 3_000,
            paymentSourceAccountId: "acc-personal"
        ))

        do {
            try await store.updateTransaction(id: tx.id, UpdateTransactionInput(description: "Правка"))
            XCTFail("editing a pending RPC-created triplet must be blocked")
        } catch let error as OfflineMutationError {
            guard case .pendingAutoTransferEdit = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - Offline update

    func test_offlineUpdate_ofPendingCreate_coalescesAndMutatesLocally() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])
        let tx = try await store.addTransaction(makeCreateInput(amount: 500))

        try await store.updateTransaction(id: tx.id, UpdateTransactionInput(
            amount: 750, amount_native: 750, description: "Исправлено"
        ))

        XCTAssertEqual(store.offlineQueue.pendingCount, 1, "update coalesces into the queued create")
        XCTAssertEqual(store.transactions.first?.amountNative, 750_00)
        XCTAssertEqual(store.transactions.first?.description, "Исправлено")
        XCTAssertEqual(store.balance(for: store.accounts[0]), 99_250_00, "balance reflects the edited amount")
    }

    func test_offlineUpdate_ofSyncedRow_queuesUpdate() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])
        // Row that already exists server-side (came from a fetch, not the queue).
        store.transactions = [Transaction(
            id: "tx-synced", userId: "u1", accountId: "acc-1",
            amount: 500_00, amountNative: 500_00, currency: "RUB",
            description: "Старое", categoryId: nil, type: .expense,
            date: "2026-07-01", merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
        )]
        store.rebuildCaches()

        try await store.updateTransaction(id: "tx-synced", UpdateTransactionInput(description: "Новое"))

        XCTAssertEqual(store.offlineQueue.pendingCount, 1)
        XCTAssertEqual(store.transactions.first?.description, "Новое")
        XCTAssertEqual(store.transactions.first?.status, "pending")
    }

    // MARK: - Offline delete

    func test_offlineDelete_ofPendingCreate_cancelsEverything() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])
        let tx = try await store.addTransaction(makeCreateInput())
        XCTAssertEqual(store.offlineQueue.pendingCount, 1)

        await store.deleteTransaction(tx)

        XCTAssertEqual(store.offlineQueue.pendingCount, 0, "delete of a queued create cancels it — nothing syncs")
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertEqual(store.balance(for: store.accounts[0]), 100_000_00, "balance back to initial")
    }

    func test_offlineDelete_ofPendingTriplet_removesAllThreeRows() async throws {
        let store = makeOfflineStore(accounts: [
            makeAccount(id: "acc-shared", name: "Семейный"),
            makeAccount(id: "acc-personal", name: "Личный")
        ])
        let tx = try await store.addTransaction(makeCreateInput(
            accountId: "acc-shared", amount: 3_000,
            paymentSourceAccountId: "acc-personal"
        ))
        XCTAssertEqual(store.transactions.count, 3)

        await store.deleteTransaction(tx)

        XCTAssertTrue(store.transactions.isEmpty, "all three placeholder rows removed")
        XCTAssertEqual(store.offlineQueue.pendingCount, 0)
    }

    // MARK: - Pending overlay

    func test_applyPendingOverlay_resurrectsQueuedRowsAfterFetchOverwrite() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])
        let queued = try await store.addTransaction(makeCreateInput(amount: 500))

        // Simulate a server fetch landing while the op is still queued
        // (flaky connectivity): the fresh array has no placeholder.
        let serverRow = Transaction(
            id: "tx-server", userId: "u1", accountId: "acc-1",
            amount: 100_00, amountNative: 100_00, currency: "RUB",
            description: "С сервера", categoryId: nil, type: .expense,
            date: "2026-07-01", merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
        )
        store.transactions = [serverRow]

        store.applyPendingOverlay()

        XCTAssertEqual(store.transactions.count, 2, "queued create re-materializes on top of server rows")
        XCTAssertTrue(store.transactions.contains { $0.id == queued.id && $0.status == "pending" })
        XCTAssertTrue(store.transactions.contains { $0.id == "tx-server" })
    }

    func test_applyPendingOverlay_skipsRowsAlreadyOnServer() async throws {
        let store = makeOfflineStore(accounts: [makeAccount(id: "acc-1", name: "Карта")])
        let queued = try await store.addTransaction(makeCreateInput(amount: 500))

        // The create synced (same client id came back from the server) but
        // the op is still queued — e.g. replay response was lost.
        let syncedRow = Transaction(
            id: queued.id, userId: "u1", accountId: "acc-1",
            amount: 500_00, amountNative: 500_00, currency: "RUB",
            description: "Тест", categoryId: "cat-1", type: .expense,
            date: "2026-07-04", merchantName: "Магазин", merchantFuzzy: nil,
            transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
        )
        store.transactions = [syncedRow]

        store.applyPendingOverlay()

        XCTAssertEqual(store.transactions.count, 1, "no duplicate placeholder for a row the server already has")
        XCTAssertNil(store.transactions.first?.status, "server row wins over the placeholder")
    }
}
