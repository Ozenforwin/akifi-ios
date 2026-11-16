import XCTest
import Observation
import Supabase
@testable import AkifiIOS

// MARK: - Test doubles

/// A one-shot latch async code can wait on.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Scripted server: `fetchAll` call N returns `results[N]` (the last one
/// repeats) after waiting on `gates[N]` when present.
private actor RemoteScript {
    private(set) var fetchAllCalls = 0
    private(set) var created: [CreateTransactionInput] = []
    var results: [RemoteFetchResult]
    var gates: [Int: Gate]
    var createdRows: [String: Transaction] = [:]

    init(results: [RemoteFetchResult], gates: [Int: Gate] = [:]) {
        self.results = results
        self.gates = gates
    }

    func nextFetchAll() async -> RemoteFetchResult {
        let index = fetchAllCalls
        fetchAllCalls += 1
        if let gate = gates[index] { await gate.wait() }
        return results[min(index, results.count - 1)]
    }

    func recordCreate(_ input: CreateTransactionInput) {
        created.append(input)
    }
}

/// Main-actor event log / counter shared with seam closures (Sendable,
/// unlike a captured `var`).
@MainActor
private final class Recorder {
    var events: [String] = []
    var count: Int { events.count }
    func add(_ event: String) { events.append(event) }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 2_000_000)
}

private struct WaitTimeout: Error {}

private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition() {
        if Date() > deadline { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Fixtures

private enum Fixture {
    static func account(_ id: String, initial: Int64 = 100_000_00) -> Account {
        Account(id: id, userId: "u1", name: id, icon: "💳", color: "#3B82F6",
                initialBalance: initial, currency: "RUB")
    }

    static func tx(_ id: String, account: String = "acc-1", amount: Int64 = 100_00,
                   type: TransactionType = .expense, transferGroup: String? = nil,
                   autoTransferGroup: String? = nil, description: String? = nil) -> AkifiIOS.Transaction {
        AkifiIOS.Transaction(
            id: id, userId: "u1", accountId: account, amount: amount, amountNative: amount,
            currency: "RUB", description: description, categoryId: nil, type: type,
            date: "2026-11-10", merchantName: nil, merchantFuzzy: nil,
            transferGroupId: transferGroup, autoTransferGroupId: autoTransferGroup,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    static func createInput(id: String? = nil, account: String = "acc-1", amount: Decimal = 500,
                            paymentSource: String? = nil) -> CreateTransactionInput {
        CreateTransactionInput(
            id: id, user_id: "u1", account_id: account, amount: amount, currency: "RUB",
            type: "expense", date: "2026-11-10", description: "Тест", category_id: nil,
            merchant_name: nil, payment_source_account_id: paymentSource
        )
    }

    static func result(accounts: [Account], transactions: [AkifiIOS.Transaction]) -> RemoteFetchResult {
        var r = RemoteFetchResult()
        r.accounts = accounts
        r.transactions = transactions
        r.categories = []
        r.budgets = []
        r.subscriptions = []
        r.budgetMembersByBudget = [:]
        r.profilesMap = [:]
        return r
    }

    static func tempPersistence() -> (PersistenceManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncTests-\(UUID().uuidString)", isDirectory: true)
        return (PersistenceManager(directory: dir), dir)
    }

    /// Store with every network seam stubbed: online, valid session, the
    /// given scripted remote, and a queue whose replays are recorded.
    @MainActor
    static func onlineStore(
        persistence: PersistenceManager,
        script: RemoteScript,
        online: Bool = true,
        session: Bool = true
    ) -> DataStore {
        let store = DataStore(cache: persistence)
        store.isConnectedProvider = { online }
        store.sessionValidator = { session }
        store.localSessionPresent = { session }
        store.remote = DataStoreRemote(
            fetchAll: { _ in await script.nextFetchAll() },
            fetchTransactions: { await script.nextFetchAll().transactions ?? [] },
            createTransaction: { input in
                await script.recordCreate(input)
                return Transaction.placeholder(for: input, nowISO: "2026-11-10T00:00:00Z")
            },
            updateTransaction: { _, _ in },
            deleteTransaction: { _ in }
        )
        store.offlineQueue.sessionUserIdProvider = { session ? "u1" : nil }
        store.offlineQueue.currentUserIdProvider = { "u1" }
        return store
    }
}

// MARK: - Y1 sign-out reset

@MainActor
final class SignOutResetTests: XCTestCase {
    private var tempDir: URL?

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeApp() -> (AppViewModel, PersistenceManager, Recorder) {
        let (persistence, dir) = Fixture.tempPersistence()
        tempDir = dir
        let store = DataStore(cache: persistence)
        store.isConnectedProvider = { false }
        store.offlineQueue.currentUserIdProvider = { "user-a" }
        let app = AppViewModel(dataStore: store)
        let recorder = Recorder()
        app.sessionEffects = AppViewModel.SessionEffects(
            unregisterPushToken: { recorder.events.append("unregisterPush") },
            registerPushToken: { recorder.events.append("registerPush") },
            clearDeviceState: { recorder.events.append("clearDevice") }
        )
        app.authManager.revokeRemoteSession = {
            recorder.events.append("revoke")
            throw URLError(.notConnectedToInternet)
        }
        app.authManager.removeLocalSession = { recorder.events.append("removeLocal") }
        app.authManager.isAuthenticated = true
        return (app, persistence, recorder)
    }

    private func seed(_ app: AppViewModel) async throws {
        let store = app.dataStore
        store.accounts = [Fixture.account("acc-1")]
        store.transactions = [Fixture.tx("t-1")]
        store.budgetMembersByBudget = ["b-1": [BudgetMember(id: "m", budgetId: "b-1", userId: "user-a", role: .owner)]]
        store.rebuildCaches()
        _ = try await store.addTransaction(Fixture.createInput())  // offline → queued
        app.journalViewModel.notes = [FinancialNote(id: "n-1", userId: "user-a", content: "секрет")]
        app.paymentManager.isPremium = true
        XCTAssertTrue(store.offlineQueue.hasPending)
    }

    /// Offline sign-out: the network revoke fails, everything local is
    /// still wiped and the UI leaves the signed-in state.
    func test_signOut_withNetworkFailure_wipesEverythingLocal() async throws {
        let (app, persistence, recorder) = makeApp()
        try await seed(app)
        persistence.flushPendingWrites()
        XCTAssertNotNil(persistence.loadTransactions())

        await app.signOut()

        XCTAssertFalse(app.authManager.isAuthenticated, "UI must leave the signed-in state even offline")
        XCTAssertEqual(recorder.events, ["unregisterPush", "revoke", "removeLocal", "clearDevice"],
                       "push token detached while the session exists; local session removed despite the failure")
        let store = app.dataStore
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertTrue(store.budgetMembersByBudget.isEmpty)
        XCTAssertEqual(store.balance(for: Fixture.account("acc-1")), 100_000_00, "caches rebuilt from nothing")
        XCTAssertFalse(store.offlineQueue.hasPending, "the next user must not replay this queue")
        XCTAssertNil(store.offlineQueue.ownerUserId)
        XCTAssertNil(persistence.loadTransactions(), "disk cache wiped")
        XCTAssertNil(persistence.loadPendingOps())
        XCTAssertTrue(app.journalViewModel.notes.isEmpty)
        XCTAssertFalse(app.paymentManager.isPremium)
        XCTAssertFalse(app.hasLoadedData)
    }

    /// A late background cache write must not resurrect the previous
    /// user's data after the wipe.
    func test_signOut_dropsPendingBackgroundWrites() async throws {
        let (app, persistence, _) = makeApp()
        try await seed(app)
        // Queued but (maybe) not yet written:
        persistence.saveTransactions([Fixture.tx("late")])

        await app.signOut()
        persistence.flushPendingWrites()

        XCTAssertNil(persistence.loadTransactions())
    }

    /// The SDK ended the session (refresh token dead): data is wiped, the
    /// owner-tagged queue is kept for the same user's next sign-in.
    func test_forcedSignOut_keepsOwnerTaggedQueue() async throws {
        let (app, persistence, _) = makeApp()
        try await seed(app)

        app.authManager.onSessionEnded?()

        XCTAssertTrue(app.dataStore.transactions.isEmpty)
        XCTAssertTrue(app.dataStore.offlineQueue.hasPending)
        XCTAssertEqual(persistence.loadPendingOps()?.count, 1)
        XCTAssertEqual(app.dataStore.offlineQueue.ownerUserId, "user-a")
    }

    /// Another user signs in on this device: the previous user's queued
    /// ops are dropped, never replayed under the new session.
    func test_adoptOwner_dropsAnotherUsersQueue() async throws {
        let (app, _, _) = makeApp()
        try await seed(app)
        let queue = app.dataStore.offlineQueue

        queue.adoptOwner("user-a")
        XCTAssertTrue(queue.hasPending, "same user keeps their queue")

        queue.adoptOwner("user-b")
        XCTAssertFalse(queue.hasPending)
        XCTAssertEqual(queue.ownerUserId, "user-b")
    }

    func test_processQueue_refusesAnotherUsersSession() async throws {
        let (app, _, _) = makeApp()
        try await seed(app)
        let queue = app.dataStore.offlineQueue
        let replayed = Recorder()
        queue.replayOperation = { _ in replayed.add("replay") }
        queue.sessionUserIdProvider = { "user-b" }

        await queue.processQueue()

        XCTAssertEqual(replayed.count, 0)
        XCTAssertTrue(queue.hasPending)
    }
}

// MARK: - Offline queue replay

@MainActor
final class OfflineQueueReplayTests: XCTestCase {
    private var tempDir: URL?

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeQueue() -> OfflineQueue {
        let (persistence, dir) = Fixture.tempPersistence()
        tempDir = dir
        let queue = OfflineQueue(persistence: persistence)
        queue.sessionUserIdProvider = { "u1" }
        queue.currentUserIdProvider = { "u1" }
        return queue
    }

    private func create(_ id: String, paymentSource: String? = nil) -> PendingOperation {
        PendingOperation(operation: .create(Fixture.createInput(id: id, paymentSource: paymentSource)))
    }

    // Y3: a replay of a create that already committed (lost response).

    func test_duplicateKeyOnReplay_resolvesAsSynced_forPlainAndRPCCreates() async {
        let queue = makeQueue()
        queue.enqueue(create("tx-plain"))
        queue.enqueue(create("tx-rpc", paymentSource: "acc-2"))
        let calls = Recorder()
        queue.replayOperation = { op in
            calls.add(op.targetTransactionId ?? "?")
            throw PostgrestError(code: "23505", message: "duplicate key value violates unique constraint \"transactions_pkey\"")
        }

        await queue.processQueue()

        XCTAssertEqual(calls.events, ["tx-plain", "tx-rpc"])
        XCTAssertFalse(queue.hasPending, "both already exist on the server — dropped, not duplicated")
        XCTAssertTrue(queue.deadLetterOperations.isEmpty)
    }

    func test_rpcParams_carryClientIdAndAllFourteenKeys() throws {
        let input = Fixture.createInput(id: "11111111-2222-3333-4444-555555555555", account: "acc-1", paymentSource: "acc-2")
        let params = try CreateExpenseWithAutoTransferParams(input: input)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])

        XCTAssertEqual(json["p_id"] as? String, input.id)
        XCTAssertEqual(Set(json.keys), [
            "p_id", "p_account_id", "p_category_id", "p_amount", "p_currency", "p_date",
            "p_description", "p_merchant_name", "p_payment_source_account_id",
            "p_source_amount", "p_source_currency", "p_foreign_amount", "p_foreign_currency", "p_fx_rate",
        ], "every key present (explicit nulls) — the key set picks the 14-arg overload")
        XCTAssertTrue(json["p_fx_rate"] is NSNull)
    }

    // Y4: never coalesce into the op on the wire.

    func test_updateDuringInFlightCreate_isAppendedAndReplayedAfterIt() async throws {
        let queue = makeQueue()
        queue.enqueue(create("tx-1"))
        let gate = Gate()
        let replayed = Recorder()
        queue.replayOperation = { op in
            if op.isCreate { await gate.wait() }
            switch op.operation {
            case .create(let input): replayed.add("create:\(input.description ?? "")")
            case .update(_, let input): replayed.add("update:\(input.description ?? "")")
            case .delete: replayed.add("delete")
            }
        }

        let round = Task { await queue.processQueue() }
        try await waitUntil { queue.inFlightOperationId != nil }

        queue.enqueue(PendingOperation(operation: .update(transactionId: "tx-1", UpdateTransactionInput(description: "Правка"))))
        XCTAssertEqual(queue.pendingCount, 2, "the in-flight create can't absorb the edit")
        if case .create(let sent) = queue.pendingOperations[0].operation {
            XCTAssertEqual(sent.description, "Тест", "the payload on the wire is not rewritten")
        }

        await gate.open()
        await round.value

        XCTAssertEqual(replayed.events, ["create:Тест", "update:Правка"], "edit replays in the same round, after the create")
        XCTAssertFalse(queue.hasPending)
    }

    func test_deleteDuringInFlightCreate_keepsCreateAndAppendsDelete() async throws {
        let queue = makeQueue()
        queue.enqueue(create("tx-1"))
        let gate = Gate()
        let replayed = Recorder()
        queue.replayOperation = { op in
            if op.isCreate { await gate.wait() }
            replayed.add(op.isCreate ? "create" : "other")
        }

        let round = Task { await queue.processQueue() }
        try await waitUntil { queue.inFlightOperationId != nil }

        queue.enqueue(PendingOperation(operation: .delete(transactionId: "tx-1")))
        XCTAssertEqual(queue.pendingCount, 2, "cancelling locally would leave the row on the server")

        await gate.open()
        await round.value
        XCTAssertEqual(replayed.events, ["create", "other"])
    }

    /// A create whose earlier replay died without an answer may exist on
    /// the server: a later delete must replay, not cancel it.
    func test_deleteAfterHaltedCreate_isNotCancelledLocally() async {
        let queue = makeQueue()
        queue.enqueue(create("tx-1"))
        queue.replayOperation = { _ in throw URLError(.timedOut) }
        await queue.processQueue()
        XCTAssertTrue(queue.pendingOperations[0].mayExistOnServer)

        queue.enqueue(PendingOperation(operation: .delete(transactionId: "tx-1")))

        XCTAssertEqual(queue.pendingCount, 2)
    }

    /// A never-sent create is still cancelled outright by a delete.
    func test_deleteOfUnsentCreate_cancelsIt() {
        let queue = makeQueue()
        queue.enqueue(create("tx-1"))
        queue.enqueue(PendingOperation(operation: .delete(transactionId: "tx-1")))
        XCTAssertFalse(queue.hasPending)
    }

    // Y2: no session = offline.

    func test_noSession_postponesReplay() async {
        let queue = makeQueue()
        queue.enqueue(create("tx-1"))
        let replayed = Recorder()
        queue.replayOperation = { _ in replayed.add("replay") }
        queue.sessionUserIdProvider = { nil }

        await queue.processQueue()

        XCTAssertEqual(replayed.count, 0, "as anon the replay would 'succeed' into nothing")
        XCTAssertEqual(queue.pendingCount, 1)
    }

    // Y5

    func test_transientError_keepsQueueWithoutBurningAttempts() async {
        let queue = makeQueue()
        queue.enqueue(create("tx-1"))
        queue.enqueue(create("tx-2"))
        let calls = Recorder()
        queue.replayOperation = { _ in
            calls.add("replay")
            throw PostgrestError(code: "PGRST003", message: "Timed out acquiring connection from connection pool.")
        }

        for _ in 0..<5 { await queue.processQueue() }

        XCTAssertEqual(calls.count, 5, "each round halts at the first op")
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(queue.pendingOperations.map(\.attempts), [0, 0])
        XCTAssertTrue(queue.deadLetterOperations.isEmpty)
    }

    /// An RPC create that keeps failing: the edit queued behind it is
    /// blocked (never overtakes it), dead-letters with it, and "Повторить"
    /// brings both back in order with a fresh budget.
    func test_deadLetter_takesDependentsAlong_andRetryRestoresOrder() async {
        let queue = makeQueue()
        queue.enqueue(create("tx-1", paymentSource: "acc-2"))
        let clock = TestClock()
        queue.now = { clock.now }
        let attempted = Recorder()
        queue.replayOperation = { op in
            attempted.add(op.isCreate ? "create" : "update")
            if op.isCreate { throw PostgrestError(code: "42501", message: "permission denied") }
        }

        await queue.processQueue()
        queue.enqueue(PendingOperation(operation: .update(transactionId: "tx-1", UpdateTransactionInput(description: "x"))))
        XCTAssertEqual(queue.pendingCount, 2, "the RPC create may exist server-side — the edit is appended, not folded")

        for _ in 1..<OfflineQueue.maxAttempts {
            clock.now = clock.now.addingTimeInterval(OfflineQueue.attemptWindow + 1)
            await queue.processQueue()
        }

        XCTAssertEqual(attempted.events, Array(repeating: "create", count: OfflineQueue.maxAttempts),
                       "the edit never replays ahead of its failing create")
        XCTAssertFalse(queue.hasPending)
        XCTAssertEqual(queue.deadLetterOperations.count, 2, "the dependent edit goes with it")

        let replayed = Recorder()
        queue.replayOperation = { op in replayed.add(op.isCreate ? "create" : "update") }
        queue.retryDeadLetters()
        XCTAssertEqual(queue.pendingOperations.map(\.attempts), [0, 0], "fresh attempt budget")
        await queue.processQueue()
        XCTAssertEqual(replayed.events, ["create", "update"])
        XCTAssertFalse(queue.hasPending)
        XCTAssertTrue(queue.deadLetterOperations.isEmpty)
    }
}

// MARK: - DataStore routing (Y4, Y9) and loads (Y2, Y6, P2)

@MainActor
final class DataStoreSyncTests: XCTestCase {
    private var tempDir: URL?
    private var persistence: PersistenceManager!

    override func setUp() async throws {
        try await super.setUp()
        let (p, dir) = Fixture.tempPersistence()
        persistence = p
        tempDir = dir
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // Y9

    func test_deletingPlaceholderLeg_cancelsTheQueuedTriplet() async throws {
        let script = RemoteScript(results: [RemoteFetchResult()])
        let store = Fixture.onlineStore(persistence: persistence, script: script, online: false)
        store.accounts = [Fixture.account("acc-shared"), Fixture.account("acc-personal")]
        store.rebuildCaches()
        let expense = try await store.addTransaction(Fixture.createInput(account: "acc-shared", amount: 3_000, paymentSource: "acc-personal"))
        let outLeg = try XCTUnwrap(store.transactions.first { $0.id == "\(expense.id)-out" })

        XCTAssertEqual(store.deletionTarget(for: outLeg).id, expense.id, "leg maps to its expense")
        await store.deleteTransaction(outLeg)

        XCTAssertFalse(store.offlineQueue.hasPending, "create cancelled — nothing syncs, no non-UUID delete dead-letters")
        XCTAssertTrue(store.transactions.isEmpty, "all three placeholder rows gone")
    }

    func test_deletionTarget_mapsSyncedLegToExpense() {
        let store = DataStore(cache: persistence)
        store.transactions = [
            Fixture.tx("exp", account: "acc-shared", autoTransferGroup: "g"),
            Fixture.tx("leg-in", account: "acc-shared", type: .income, transferGroup: "g", autoTransferGroup: "g"),
            Fixture.tx("plain"),
        ]
        XCTAssertEqual(store.deletionTarget(for: store.transactions[1]).id, "exp")
        XCTAssertEqual(store.deletionTarget(for: store.transactions[2]).id, "plain")
    }

    // Y4: online, but the row's create is still queued → through the queue.

    func test_onlineEditOfQueuedRow_goesThroughQueue() async throws {
        let script = RemoteScript(results: [RemoteFetchResult()])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        store.isConnectedProvider = { false }
        let directUpdates = Recorder()
        store.remote.updateTransaction = { _, _ in
            await directUpdates.add("update")
        }
        store.offlineQueue.replayOperation = { _ in throw URLError(.notConnectedToInternet) }
        store.accounts = [Fixture.account("acc-1")]
        store.rebuildCaches()
        let tx = try await store.addTransaction(Fixture.createInput())

        store.isConnectedProvider = { true }
        try await store.updateTransaction(id: tx.id, UpdateTransactionInput(amount: 900, amount_native: 900))

        XCTAssertEqual(directUpdates.count, 0, "a direct UPDATE would match zero rows and 'succeed'")
        XCTAssertEqual(store.offlineQueue.pendingCount, 1, "folded into the queued create")
        if case .create(let input) = store.offlineQueue.pendingOperations[0].operation {
            XCTAssertEqual(input.amount, 900)
        } else {
            XCTFail("expected the create")
        }
    }

    // Y2

    func test_loadAll_withoutSession_keepsCacheAndNeitherFetchesNorReplays() async throws {
        let script = RemoteScript(results: [Fixture.result(accounts: [], transactions: [])])
        persistence.saveAccounts([Fixture.account("acc-1")])
        persistence.saveTransactions([Fixture.tx("cached")])
        persistence.flushPendingWrites()
        let store = Fixture.onlineStore(persistence: persistence, script: script, session: false)
        await store.loadCachedDataIfNeeded()
        // Queue something to prove it isn't replayed. Online but sessionless
        // counts as offline, so this create goes to the queue.
        _ = try await store.addTransaction(Fixture.createInput())
        XCTAssertTrue(store.offlineQueue.hasPending)
        let replays = Recorder()
        store.offlineQueue.replayOperation = { _ in replays.add("replay") }

        await store.loadAll()

        let calls = await script.fetchAllCalls
        XCTAssertEqual(calls, 0, "anon reads would come back empty — don't make them")
        XCTAssertEqual(replays.count, 0)
        XCTAssertTrue(store.transactions.contains { $0.id == "cached" }, "cache stays on screen")
        XCTAssertNil(store.lastCompleteLoadAt)
    }

    /// P8 made cache writes asynchronous; the queue file stays synchronous.
    /// A queued entry whose cache write never landed (app killed) must still
    /// show on the next cold start.
    func test_coldStart_restoresQueuedEntryMissingFromCache() async throws {
        let first = DataStore(cache: persistence)
        first.isConnectedProvider = { false }
        first.offlineQueue.currentUserIdProvider = { "u1" }
        let queued = try await first.addTransaction(Fixture.createInput())
        persistence.flushPendingWrites()
        persistence.saveTransactions([Fixture.tx("older")])  // cache without the entry
        persistence.flushPendingWrites()

        let relaunched = DataStore(cache: persistence)
        relaunched.isConnectedProvider = { false }
        await relaunched.loadCachedDataIfNeeded()

        XCTAssertEqual(Set(relaunched.transactions.map(\.id)), ["older", queued.id])
    }

    func test_loadAll_sessionLostMidFlight_discardsResult() async {
        let script = RemoteScript(results: [Fixture.result(accounts: [], transactions: [])])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        store.accounts = [Fixture.account("acc-1")]
        store.transactions = [Fixture.tx("t-1")]
        store.localSessionPresent = { false }

        await store.loadAll()

        XCTAssertEqual(store.transactions.map(\.id), ["t-1"], "empty anon result must not replace real data")
    }

    // Y6

    func test_concurrentLoadAll_isSingleFlightWithOneRerun() async throws {
        let gate = Gate()
        let first = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [Fixture.tx("old")])
        let second = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [Fixture.tx("new")])
        let script = RemoteScript(results: [first, second], gates: [0: gate])
        let store = Fixture.onlineStore(persistence: persistence, script: script)

        let a = Task { await store.loadAll() }
        try await waitUntil { await script.fetchAllCalls == 1 }
        let b = Task { await store.loadAll() }
        let c = Task { await store.loadAll() }
        try await Task.sleep(for: .milliseconds(20))
        let duringFirst = await script.fetchAllCalls
        XCTAssertEqual(duringFirst, 1, "joiners don't start their own fetch")

        await gate.open()
        await a.value
        await b.value
        await c.value

        let total = await script.fetchAllCalls
        XCTAssertEqual(total, 2, "one load + one re-run for all joiners, not one per caller")
        XCTAssertEqual(store.transactions.map(\.id), ["new"], "every caller returns with the re-run's data")
    }

    /// The reported race: a refresh starts, the user saves, the stale
    /// refresh lands last and the new row disappears.
    func test_resultOlderThanLocalMutation_isDroppedAndRerun() async throws {
        let gate = Gate()
        let stale = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [Fixture.tx("a")])
        let fresh = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [Fixture.tx("y"), Fixture.tx("a")])
        let script = RemoteScript(results: [stale, fresh], gates: [0: gate])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        store.accounts = [Fixture.account("acc-1")]
        store.transactions = [Fixture.tx("a")]
        store.rebuildCaches()
        store.remote.createTransaction = { _ in Fixture.tx("y") }

        let load = Task { await store.loadAll() }
        try await waitUntil { await script.fetchAllCalls == 1 }

        _ = try await store.addTransaction(Fixture.createInput())  // online, direct
        XCTAssertTrue(store.transactions.contains { $0.id == "y" })

        await gate.open()
        await load.value

        XCTAssertTrue(store.transactions.contains { $0.id == "y" }, "the stale list must not erase the new row")
        let calls = await script.fetchAllCalls
        XCTAssertEqual(calls, 2, "stale result dropped and the load re-run")
        XCTAssertEqual(store.transactions.map(\.id), ["y", "a"])
    }

    // P2: a refresh that changes nothing invalidates nothing.

    func test_loadAll_withUnchangedData_triggersNoObservableWrite() async {
        let accounts = [Fixture.account("acc-1")]
        let txs = [Fixture.tx("a"), Fixture.tx("b")]
        let script = RemoteScript(results: [Fixture.result(accounts: accounts, transactions: txs)])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        store.accounts = accounts
        store.transactions = txs
        store.categories = []
        store.rebuildCaches()

        let fired = Recorder()
        withObservationTracking {
            _ = store.accounts
            _ = store.transactions
            _ = store.categories
            _ = store.budgets
            _ = store.subscriptions
            _ = store.profilesMap
            _ = store.balance(for: accounts[0])
        } onChange: {
            MainActor.assumeIsolated { fired.add("changed") }
        }

        await store.loadAll()

        XCTAssertEqual(fired.count, 0, "equal data must not be reassigned")
        XCTAssertNotNil(store.lastCompleteLoadAt)
    }

    func test_rebuildCaches_withoutChange_keepsRevisionAndCategories() {
        let store = DataStore(cache: persistence)
        store.accounts = [Fixture.account("acc-1")]
        store.transactions = [Fixture.tx("a")]
        store.categories = [AkifiIOS.Category(id: "c", userId: "u1", accountId: nil, name: "Еда", icon: "🍔",
                                              color: "#000", type: .expense, isActive: true, createdAt: nil)]
        store.rebuildCaches()
        let revision = store.derivedRevision

        let categoriesWritten = Recorder()
        withObservationTracking { _ = store.categories } onChange: {
            MainActor.assumeIsolated { categoriesWritten.add("written") }
        }
        store.rebuildCaches()

        XCTAssertEqual(store.derivedRevision, revision)
        XCTAssertEqual(categoriesWritten.count, 0)

        store.transactions.insert(Fixture.tx("b", amount: 50_00), at: 0)
        store.rebuildCaches()
        XCTAssertNotEqual(store.derivedRevision, revision, "a balance change bumps the revision once")
    }

    // Y8

    func test_netWorthSnapshot_requiresCompleteLoad() async {
        let script = RemoteScript(results: [Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [])])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        XCTAssertFalse(NetWorthViewModel.canCaptureSnapshot(allFetchesSucceeded: true, dataStore: store),
                       "cache-only data must not become the day's snapshot")

        await store.loadAll()
        XCTAssertTrue(NetWorthViewModel.canCaptureSnapshot(allFetchesSucceeded: true, dataStore: store))
        XCTAssertFalse(NetWorthViewModel.canCaptureSnapshot(allFetchesSucceeded: false, dataStore: store),
                       "a failed liabilities fetch would inflate net worth")

        var partial = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [])
        partial.transactions = nil
        let partialStore = Fixture.onlineStore(persistence: persistence, script: RemoteScript(results: [partial]))
        await partialStore.loadAll()
        XCTAssertNil(partialStore.lastCompleteLoadAt)
    }

    // Y7

    func test_failedDelete_isSurfacedAndThrownAndLeavesRow() async throws {
        let script = RemoteScript(results: [RemoteFetchResult()])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        store.remote.deleteTransaction = { _ in throw PostgrestError(code: "42501", message: "permission denied") }
        store.transactions = [Fixture.tx("t-1")]

        do {
            try await store.deleteTransactionThrowing(store.transactions[0])
            XCTFail("must throw")
        } catch {}
        XCTAssertEqual(store.transactions.count, 1)

        let ok = await store.deleteTransaction(store.transactions[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(store.issue?.kind, .mutation, "the banner shows it")
    }

    func test_partialLoad_raisesLoadIssue_andCleanLoadClearsIt() async {
        var partial = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [])
        partial.budgets = nil
        partial.failures = ["budgets"]
        let clean = Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [])
        let script = RemoteScript(results: [partial, clean])
        let store = Fixture.onlineStore(persistence: persistence, script: script)

        await store.loadAll()
        XCTAssertEqual(store.issue?.kind, .load)
        await store.loadAll()
        XCTAssertNil(store.issue)
    }

    // buildAssistantContext must not count transfer legs.

    func test_assistantContext_excludesTransferLegs() {
        let store = DataStore(cache: persistence)
        store.accounts = [Fixture.account("acc-shared"), Fixture.account("acc-personal")]
        store.transactions = [
            Fixture.tx("exp", account: "acc-shared", amount: 3_000_00, autoTransferGroup: "g"),
            Fixture.tx("out", account: "acc-personal", amount: 3_000_00, transferGroup: "g", autoTransferGroup: "g"),
            Fixture.tx("in", account: "acc-shared", amount: 3_000_00, type: .income, transferGroup: "g", autoTransferGroup: "g"),
        ]
        store.rebuildCaches()

        let summary = store.buildAssistantContext().transactionSummary

        XCTAssertEqual(summary.totalExpense, 3_000, accuracy: 0.001, "the expense once, not expense + out-leg")
        XCTAssertEqual(summary.totalIncome, 0, accuracy: 0.001, "the in-leg isn't income")
        XCTAssertNil(summary.byAccount["acc-personal"], "the out-leg isn't spending of the source account")
    }
}

// MARK: - B5, Y12, D10

@MainActor
final class SyncHelpersTests: XCTestCase {

    private struct Boom: Error {}

    func test_externalSpend_failedBudgetKeepsLastGoodRows() async {
        let previous = ["b-fail": [BudgetMath.ExternalSpendRow(txId: "p1", amountNative: 500, currency: "RUB", txDate: "2026-11-01")]]
        let result = await LiveDataFetch.fetchExternalSpend(
            budgetIds: ["b-ok", "b-fail"],
            previous: previous
        ) { budgetId in
            if budgetId == "b-fail" { throw Boom() }
            return [BudgetMath.ExternalSpendRow(txId: "x", amountNative: 100, currency: "RUB", txDate: "2026-11-02")]
        }

        XCTAssertEqual(result.rows["b-ok"]?.map(\.txId), ["x"])
        XCTAssertEqual(result.rows["b-fail"]?.map(\.txId), ["p1"], "a 504 must not silently drop the partner's spending")
        XCTAssertEqual(result.incomplete, ["b-fail"])
    }

    func test_journalPage_appendSkipsKnownNotes_andCursorIsLastRow() {
        let local = FinancialNote(id: "n-new", userId: "u", content: "свежая", createdAt: "2026-11-17T10:00:00+00:00")
        let page1 = [
            FinancialNote(id: "n-2", userId: "u", content: "b", createdAt: "2026-11-16T10:00:00+00:00"),
            FinancialNote(id: "n-1", userId: "u", content: "a", createdAt: "2026-11-15T10:00:00+00:00"),
        ]
        let page2 = [
            local,  // came back again after being inserted locally
            FinancialNote(id: "n-0", userId: "u", content: "z", createdAt: "2026-11-14T10:00:00+00:00"),
        ]

        let merged = JournalViewModel.appendingPage(page2, to: [local] + page1)

        XCTAssertEqual(merged.map(\.id), ["n-new", "n-2", "n-1", "n-0"])
        XCTAssertEqual(JournalViewModel.cursor(after: page1),
                       FinancialNoteRepository.PageCursor(createdAt: "2026-11-15T10:00:00+00:00", id: "n-1"))
        XCTAssertNil(JournalViewModel.cursor(after: []))
    }

    func test_goalAge_parsesFullTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!

        XCTAssertEqual(SavingsViewModel.goalAgeDays(createdAt: "2026-11-01T08:15:30.123456+00:00", now: now, calendar: calendar), 16)
        XCTAssertEqual(SavingsViewModel.goalAgeDays(createdAt: "2026-11-07T08:15:30+00:00", now: now, calendar: calendar), 10)
        XCTAssertEqual(SavingsViewModel.goalAgeDays(createdAt: "2026-11-12", now: now, calendar: calendar), 5)
        XCTAssertEqual(SavingsViewModel.goalAgeDays(createdAt: nil, now: now, calendar: calendar), 1)
        XCTAssertEqual(SavingsViewModel.goalAgeDays(createdAt: "2026-11-17T09:00:00+00:00", now: now, calendar: calendar), 1)
    }
}
