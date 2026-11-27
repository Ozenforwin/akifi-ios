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
        store.currentUserIdProvider = { "u1" }
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
        store.allAccounts = [Fixture.account("acc-1")]
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
        XCTAssertEqual(recorder.events, ["unregisterPush", "clearDevice", "revoke", "removeLocal"],
                       "push token detached while the session exists; local data wiped BEFORE the session goes (Y3); local session removed despite the failure")
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
            case .deleteTransferGroup: replayed.add("deleteGroup")
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
        store.allAccounts = [Fixture.account("acc-shared"), Fixture.account("acc-personal")]
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
        store.allAccounts = [Fixture.account("acc-1")]
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
        persistence.saveCacheOwner("u1")  // Y3: only the owner's cache is shown
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
        first.currentUserIdProvider = { "u1" }
        let queued = try await first.addTransaction(Fixture.createInput())
        persistence.flushPendingWrites()
        persistence.saveTransactions([Fixture.tx("older")])  // cache without the entry
        persistence.flushPendingWrites()

        let relaunched = DataStore(cache: persistence)
        relaunched.isConnectedProvider = { false }
        relaunched.currentUserIdProvider = { "u1" }
        await relaunched.loadCachedDataIfNeeded()

        XCTAssertEqual(Set(relaunched.transactions.map(\.id)), ["older", queued.id])
    }

    func test_loadAll_sessionLostMidFlight_discardsResult() async {
        let script = RemoteScript(results: [Fixture.result(accounts: [], transactions: [])])
        let store = Fixture.onlineStore(persistence: persistence, script: script)
        store.allAccounts = [Fixture.account("acc-1")]
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
        store.allAccounts = [Fixture.account("acc-1")]
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
        store.allAccounts = accounts
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
        store.allAccounts = [Fixture.account("acc-1")]
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
        store.allAccounts = [Fixture.account("acc-shared"), Fixture.account("acc-personal")]
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

// MARK: - 2026-11-27 review, sync stream (Y1–Y9, N2, N5)

/// Y1: the SDK ending the session on its own must reach the sign-in screen,
/// keep the owner-tagged queue, and never leave the app "signed in" with
/// nothing behind it.
@MainActor
final class SessionEndRoutingTests: XCTestCase {
    private var tempDir: URL?

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeApp(online: Bool = false) -> (AppViewModel, PersistenceManager, Recorder) {
        let (persistence, dir) = Fixture.tempPersistence()
        tempDir = dir
        let store = DataStore(cache: persistence)
        store.isConnectedProvider = { online }
        store.offlineQueue.currentUserIdProvider = { "user-a" }
        store.currentUserIdProvider = { "user-a" }
        let app = AppViewModel(dataStore: store)
        let recorder = Recorder()
        app.sessionEffects = AppViewModel.SessionEffects(
            unregisterPushToken: { recorder.add("unregisterPush") },
            registerPushToken: { recorder.add("registerPush") },
            clearDeviceState: { recorder.add("clearDevice") }
        )
        app.authManager.revokeRemoteSession = { recorder.add("revoke") }
        app.authManager.removeLocalSession = { recorder.add("removeLocal") }
        app.authManager.sdkHasSession = { false }
        app.authManager.isAuthenticated = true
        return (app, persistence, recorder)
    }

    func test_Y1_unrequestedSignedOut_showsSignIn_keepsQueueForTheSameUser() async throws {
        let (app, persistence, _) = makeApp()
        let store = app.dataStore
        store.allAccounts = [Fixture.account("acc-1")]
        _ = try await store.addTransaction(Fixture.createInput())  // offline → queued
        XCTAssertEqual(store.offlineQueue.pendingCount, 1)

        app.authManager.handleAuthEvent(.signedOut, session: nil)

        XCTAssertFalse(app.authManager.isAuthenticated, "the sign-in screen, not a silent dead app")
        XCTAssertTrue(app.authManager.sessionEndedUnexpectedly, "LoginView explains why")
        XCTAssertTrue(store.transactions.isEmpty, "the previous session's data is wiped")
        XCTAssertEqual(persistence.loadPendingOps()?.count, 1, "unsynced entries survive")
        XCTAssertEqual(store.offlineQueue.ownerUserId, "user-a")

        // The same user signs back in: the queue replays.
        store.offlineQueue.adoptOwner("user-a")
        let replayed = Recorder()
        store.offlineQueue.replayOperation = { _ in replayed.add("replay") }
        store.offlineQueue.sessionUserIdProvider = { "user-a" }
        await store.offlineQueue.processQueue()
        XCTAssertEqual(replayed.count, 1)
        XCTAssertFalse(store.offlineQueue.hasPending)
    }

    func test_Y1_explicitSignOut_itsOwnSignedOutEventIsNotAForcedOne() async throws {
        let (app, persistence, recorder) = makeApp()
        _ = try await app.dataStore.addTransaction(Fixture.createInput())
        // The SDK emits `.signedOut` while the revoke runs.
        app.authManager.revokeRemoteSession = { [weak app] in
            recorder.add("revoke")
            app?.authManager.handleAuthEvent(.signedOut, session: nil)
        }

        await app.signOut()

        XCTAssertFalse(app.authManager.isAuthenticated)
        XCTAssertFalse(app.authManager.sessionEndedUnexpectedly, "the user asked for it")
        XCTAssertFalse(app.dataStore.offlineQueue.hasPending, "an explicit sign-out discards the queue (after its warning)")
        XCTAssertNil(persistence.loadPendingOps())
        XCTAssertEqual(recorder.events.filter { $0 == "clearDevice" }.count, 1, "one reset, no forced one on top")
    }

    func test_Y1_signedOutWhileTheSDKHoldsANewSession_isIgnored() {
        let (app, _, _) = makeApp()
        app.authManager.sdkHasSession = { true }  // a quick re-sign-in already stored one

        app.authManager.handleAuthEvent(.signedOut, session: nil)

        XCTAssertTrue(app.authManager.isAuthenticated)
        XCTAssertFalse(app.authManager.sessionEndedUnexpectedly)
    }

    func test_Y1_routingRule() {
        XCTAssertTrue(AuthManager.isForcedSignOut(event: .signedOut, isAuthenticated: true, explicitSignOutInProgress: false, sdkHasSession: false))
        XCTAssertTrue(AuthManager.isForcedSignOut(event: .userDeleted, isAuthenticated: true, explicitSignOutInProgress: false, sdkHasSession: false))
        XCTAssertFalse(AuthManager.isForcedSignOut(event: .signedOut, isAuthenticated: false, explicitSignOutInProgress: false, sdkHasSession: false),
                       "already on the sign-in screen")
        XCTAssertFalse(AuthManager.isForcedSignOut(event: .signedOut, isAuthenticated: true, explicitSignOutInProgress: true, sdkHasSession: false))
        XCTAssertFalse(AuthManager.isForcedSignOut(event: .tokenRefreshed, isAuthenticated: true, explicitSignOutInProgress: false, sdkHasSession: false))
        XCTAssertFalse(AuthManager.isForcedSignOut(event: .initialSession, isAuthenticated: true, explicitSignOutInProgress: false, sdkHasSession: false))
    }

    func test_Y1_sessionMissing_isADefinitiveEnd() {
        XCTAssertTrue(AuthManager.isDefinitivelyExpired(AuthError.sessionMissing),
                      "what supabase-swift throws after it deleted the session itself")
        let response = HTTPURLResponse(url: URL(string: "https://example.supabase.co/auth/v1/token")!,
                                       statusCode: 400, httpVersion: nil, headerFields: nil)!
        XCTAssertTrue(AuthManager.isDefinitivelyExpired(AuthError.api(
            message: "Invalid Refresh Token: Already Used", errorCode: .refreshTokenAlreadyUsed,
            underlyingData: Data(), underlyingResponse: response
        )))
        XCTAssertFalse(AuthManager.isDefinitivelyExpired(AuthError.api(
            message: "Unexpected error", errorCode: .unexpectedFailure,
            underlyingData: Data(), underlyingResponse: response
        )))
        XCTAssertFalse(AuthManager.isDefinitivelyExpired(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AuthManager.isDefinitivelyExpired(TimeoutError(seconds: 5)))
    }

    /// The event was missed (emitted while nobody listened): the next load
    /// that finds no session at all while online routes to sign-in instead
    /// of silently doing nothing forever.
    func test_Y1_onlineLoadFindingNoSessionAtAll_endsTheSession() async {
        let (app, _, _) = makeApp(online: true)
        let store = app.dataStore
        store.sessionValidator = { false }
        store.localSessionPresent = { false }
        store.currentUserIdProvider = { nil }

        await store.loadAll()

        XCTAssertFalse(app.authManager.isAuthenticated)
        XCTAssertTrue(app.authManager.sessionEndedUnexpectedly)
    }

    func test_Y1_expiredTokenWithSessionStillStored_isNotASignOut() async {
        let (app, _, _) = makeApp(online: true)
        let store = app.dataStore
        store.sessionValidator = { false }  // refresh failed transiently
        store.localSessionPresent = { false }
        store.currentUserIdProvider = { "user-a" }  // but the SDK still holds it

        await store.loadAll()

        XCTAssertTrue(app.authManager.isAuthenticated)
    }

    func test_Y1_foregroundRefreshWithoutAnSDKSession_endsTheSession() async {
        let (app, _, _) = makeApp()
        await app.authManager.refreshSessionIfNeeded()
        XCTAssertFalse(app.authManager.isAuthenticated)
        XCTAssertTrue(app.authManager.sessionEndedUnexpectedly)
    }
}

/// Y3: the disk cache belongs to one user and is never shown to another.
@MainActor
final class CacheOwnerTests: XCTestCase {
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

    private func store(user: String?) -> DataStore {
        let s = DataStore(cache: persistence)
        s.isConnectedProvider = { false }
        s.currentUserIdProvider = { user }
        s.offlineQueue.currentUserIdProvider = { user }
        return s
    }

    func test_Y3_anotherUsersCache_isNeverShown_andIsWiped() async {
        persistence.saveCacheOwner("user-a")
        persistence.saveAccounts([Fixture.account("acc-a")])
        persistence.saveTransactions([Fixture.tx("t-a")])
        persistence.flushPendingWrites()

        let b = store(user: "user-b")
        let shown = await b.loadCachedDataIfNeeded()

        XCTAssertFalse(shown, "the splash must not lift on A's balances")
        XCTAssertTrue(b.accounts.isEmpty)
        XCTAssertTrue(b.transactions.isEmpty)
        XCTAssertNil(persistence.loadAccounts(), "A's files are gone")
        XCTAssertEqual(persistence.loadCacheOwner(), "user-b")
    }

    func test_Y3_untaggedCache_isShownOnlyToTheUserOfItsProfile() async {
        persistence.saveProfile(Profile(id: "user-a", updatedAt: nil))
        persistence.saveAccounts([Fixture.account("acc-a")])
        persistence.flushPendingWrites()

        let a = store(user: "user-a")
        let shown = await a.loadCachedDataIfNeeded()

        XCTAssertTrue(shown, "a cache written by 1.5.7 for the same user still starts instantly")
        XCTAssertEqual(persistence.loadCacheOwner(), "user-a", "and is tagged from now on")
    }

    func test_Y3_cacheNobodyCanVouchFor_isNotShown() async {
        persistence.saveAccounts([Fixture.account("acc-?")])
        persistence.flushPendingWrites()

        let shown = await store(user: "user-a").loadCachedDataIfNeeded()

        XCTAssertFalse(shown)
        XCTAssertNil(persistence.loadAccounts())
    }

    func test_Y3_firstWriteOfAnotherUser_neverMixesTheirFiles() async throws {
        persistence.saveCacheOwner("user-a")
        persistence.saveAccounts([Fixture.account("acc-a")])
        persistence.flushPendingWrites()

        let b = store(user: "user-b")  // writes before any cache load
        _ = try await b.addTransaction(Fixture.createInput())
        persistence.flushPendingWrites()

        XCTAssertNil(persistence.loadAccounts(), "A's accounts must not sit next to B's transactions")
        XCTAssertEqual(persistence.loadCacheOwner(), "user-b")
        XCTAssertEqual(persistence.loadTransactions()?.count, 1)
    }
}

/// Y4 / Y5 / Y6 / Y8 / Y9: offline replay and sign-out races.
@MainActor
final class ReplayCorrectnessTests: XCTestCase {
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

    private func makeQueue() -> OfflineQueue {
        let queue = OfflineQueue(persistence: persistence)
        queue.sessionUserIdProvider = { "u1" }
        queue.currentUserIdProvider = { "u1" }
        return queue
    }

    private func httpError(status: Int) -> HTTPError {
        let response = HTTPURLResponse(url: URL(string: "https://example.supabase.co/rest/v1/transactions")!,
                                       statusCode: status, httpVersion: nil, headerFields: nil)!
        return HTTPError(data: Data("<html>error</html>".utf8), response: response)
    }

    private func leg(_ id: String, account: String, type: TransactionType, group: String) -> AkifiIOS.Transaction {
        Fixture.tx(id, account: account, amount: 1_000_00, type: type, transferGroup: group)
    }

    private func transferInput(account: String, type: String, group: String) -> CreateTransactionInput {
        CreateTransactionInput(
            user_id: "u1", account_id: account, amount: 1_000, currency: "RUB", type: type,
            date: "2026-11-10", description: nil, category_id: nil, merchant_name: nil,
            transfer_group_id: group
        )
    }

    // MARK: Y4

    func test_Y4_onlyPreSendTransportErrors_meanNotCommitted() {
        for code: URLError.Code in [.networkConnectionLost, .timedOut, .badServerResponse, .cannotParseResponse] {
            XCTAssertTrue(OfflineQueue.mayHaveCommitted(URLError(code)), "\(code)")
        }
        XCTAssertTrue(OfflineQueue.mayHaveCommitted(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        XCTAssertTrue(OfflineQueue.mayHaveCommitted(httpError(status: 502)))
        XCTAssertTrue(OfflineQueue.mayHaveCommitted(httpError(status: 503)))
        for code: URLError.Code in [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed] {
            XCTAssertFalse(OfflineQueue.mayHaveCommitted(URLError(code)), "\(code) fails before the request is sent")
        }
        XCTAssertFalse(OfflineQueue.mayHaveCommitted(PostgrestError(code: "23503", message: "fk")), "the database answered")
    }

    func test_Y4_onlineCreateWithLostResponse_keepsTheLaterEditSeparate() async throws {
        let store = Fixture.onlineStore(persistence: persistence, script: RemoteScript(results: [RemoteFetchResult()]))
        store.remote.createTransaction = { _ in throw URLError(.networkConnectionLost) }
        store.offlineQueue.replayOperation = { _ in throw URLError(.notConnectedToInternet) }
        store.allAccounts = [Fixture.account("acc-1")]

        let tx = try await store.addTransaction(Fixture.createInput(amount: 1_500))
        XCTAssertEqual(store.offlineQueue.pendingOperations.first?.mayExistOnServer, true)
        try await store.updateTransaction(id: tx.id, UpdateTransactionInput(amount: 150, amount_native: 150))

        XCTAssertEqual(store.offlineQueue.pendingCount, 2, "the edit replays as its own UPDATE behind the create")
    }

    func test_Y4_duplicateCreateCarryingAFoldedEdit_replaysTheEditAsUpdate() async {
        let queue = makeQueue()
        queue.enqueue(PendingOperation(operation: .create(Fixture.createInput(id: "tx-1", amount: 1_500))))
        queue.enqueue(PendingOperation(operation: .update(transactionId: "tx-1", UpdateTransactionInput(amount: 150, amount_native: 150))))
        XCTAssertEqual(queue.pendingCount, 1, "folded into the create")
        XCTAssertTrue(queue.pendingOperations[0].hasFoldedUpdates)
        let replayed = Recorder()
        queue.replayOperation = { op in
            switch op.operation {
            case .create:
                replayed.add("create")
                throw PostgrestError(code: "23505", message: "duplicate key value violates unique constraint")
            case .update(let id, let input):
                replayed.add("update:\(id):\(input.amount ?? 0)")
            default:
                replayed.add("other")
            }
        }

        await queue.processQueue()

        XCTAssertEqual(replayed.events, ["create", "update:tx-1:150"], "1 500 ₽ on the server becomes the 150 ₽ the user typed")
        XCTAssertFalse(queue.hasPending)
    }

    func test_Y4_duplicateCreateWithoutEdits_isSimplySynced() {
        XCTAssertEqual(OfflineQueue.outcome(
            for: PostgrestError(code: "23505", message: "dup"),
            operation: .create(Fixture.createInput(id: "t")), attempts: 0, hasFoldedUpdates: false
        ), .treatAsSynced)
    }

    // MARK: Y5

    func test_Y5_sessionLostMidRound_haltsBeforeTheNextOp() async {
        let queue = makeQueue()
        for id in ["tx-1", "tx-2", "tx-3"] {
            queue.enqueue(PendingOperation(operation: .update(transactionId: id, UpdateTransactionInput(description: id))))
        }
        let checks = Recorder()
        queue.sessionUserIdProvider = {
            checks.add("check")
            return checks.count <= 1 ? "u1" : nil  // valid at the start, expired after op 1
        }
        let replayed = Recorder()
        queue.replayOperation = { _ in replayed.add("replay") }

        await queue.processQueue()

        XCTAssertEqual(replayed.count, 1, "op 2 would have gone out as anon and 'succeeded' into nothing")
        XCTAssertEqual(queue.pendingCount, 2)
    }

    func test_Y5_zeroRowUpdate_isAFailureNotASync() {
        XCTAssertEqual(OfflineQueue.outcome(
            for: TransactionWriteError.noRowsAffected,
            operation: .update(transactionId: "t", UpdateTransactionInput(description: "x")), attempts: 0
        ), .retryCounted)
        XCTAssertFalse(OfflineQueue.shouldQueueFailedWrite(TransactionWriteError.noRowsAffected),
                       "online, the user is told the edit didn't apply")
    }

    // MARK: Y6

    func test_Y6_refusedCreate_staysVisibleAsUnsynced_raisesBanner_countsForSignOut() async throws {
        let script = RemoteScript(results: [Fixture.result(accounts: [Fixture.account("acc-1")], transactions: [])])
        let store = Fixture.onlineStore(persistence: persistence, script: script, online: false)
        store.allAccounts = [Fixture.account("acc-1")]
        let queued = try await store.addTransaction(Fixture.createInput())
        let clock = TestClock()
        store.offlineQueue.now = { clock.now }
        store.offlineQueue.replayOperation = { _ in
            throw PostgrestError(code: "23503", message: "insert violates foreign key constraint")
        }

        for _ in 0..<OfflineQueue.maxAttempts {
            await store.offlineQueue.processQueue()
            clock.now = clock.now.addingTimeInterval(OfflineQueue.attemptWindow + 1)
        }

        XCTAssertEqual(store.offlineQueue.deadLetterOperations.count, 1)
        XCTAssertEqual(store.issue?.kind, .unsynced, "a banner, not silence")
        XCTAssertEqual(store.transactions.first { $0.id == queued.id }?.isUnsynced, true)
        XCTAssertEqual(store.offlineQueue.unsyncedCount, 1, "the sign-out warning counts it")
        XCTAssertTrue(store.offlineQueue.hasUnsynced)

        // The next refresh doesn't drop it from the list (and the balance).
        store.isConnectedProvider = { true }
        await store.loadAll()
        XCTAssertEqual(store.transactions.first { $0.id == queued.id }?.isUnsynced, true)

        // «Не сохранять» removes it for good.
        await store.discardUnsyncedOperations()
        XCTAssertNil(store.transactions.first { $0.id == queued.id })
        XCTAssertNil(store.issue)
        XCTAssertFalse(store.offlineQueue.hasUnsynced)
    }

    func test_Y6_refusedDelete_showsTheRowTheServerStillHas() {
        let refused = PendingOperation(operation: .delete(transactionId: "t-1"))
        let rows = OfflineOverlay.apply([], deadLetters: [refused], to: [Fixture.tx("t-1")], nowISO: "2026-11-10T00:00:00Z")
        XCTAssertEqual(rows.map(\.id), ["t-1"])
        XCTAssertTrue(rows[0].isUnsynced)
    }

    // MARK: Y8

    func test_Y8_deletingOneLegOfASyncedTransfer_deletesBothInOneRequest() async {
        let store = Fixture.onlineStore(persistence: persistence, script: RemoteScript(results: [RemoteFetchResult()]))
        let calls = Recorder()
        store.remote.deleteTransferGroup = { group in await calls.add("group:\(group)") }
        store.remote.deleteTransaction = { id in await calls.add("row:\(id)") }
        store.allAccounts = [Fixture.account("acc-1"), Fixture.account("acc-2")]
        store.transactions = [
            leg("out", account: "acc-1", type: .expense, group: "g-1"),
            leg("in", account: "acc-2", type: .income, group: "g-1"),
            Fixture.tx("other"),
        ]
        store.rebuildCaches()

        let ok = await store.deleteTransaction(store.transactions[0])

        XCTAssertTrue(ok)
        XCTAssertEqual(calls.events, ["group:g-1"], "one request for the pair, no lone-row delete")
        XCTAssertEqual(store.transactions.map(\.id), ["other"])
        XCTAssertEqual(store.balance(for: Fixture.account("acc-2")), 100_000_00, "no orphan income left on the other account")
    }

    func test_Y8_offlineDeleteOfAnUnsyncedTransfer_cancelsBothCreates() async throws {
        let store = Fixture.onlineStore(persistence: persistence, script: RemoteScript(results: [RemoteFetchResult()]), online: false)
        store.allAccounts = [Fixture.account("acc-1"), Fixture.account("acc-2")]
        let out = try await store.addTransaction(transferInput(account: "acc-1", type: "expense", group: "G-1"))
        _ = try await store.addTransaction(transferInput(account: "acc-2", type: "income", group: "G-1"))
        XCTAssertEqual(store.offlineQueue.pendingCount, 2)

        await store.deleteTransaction(out)

        XCTAssertFalse(store.offlineQueue.hasPending, "nothing of it ever reaches the server")
        XCTAssertTrue(store.transactions.isEmpty)
    }

    func test_Y8_offlineDeleteOfASyncedTransfer_queuesOneGroupDelete() async {
        let store = Fixture.onlineStore(persistence: persistence, script: RemoteScript(results: [RemoteFetchResult()]), online: false)
        let legs = [leg("out", account: "acc-1", type: .expense, group: "g-1"), leg("in", account: "acc-2", type: .income, group: "g-1")]
        store.transactions = legs

        await store.deleteTransaction(legs[1])

        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertEqual(store.offlineQueue.pendingCount, 1)
        guard case .deleteTransferGroup(let group, let ids) = store.offlineQueue.pendingOperations[0].operation else {
            return XCTFail("expected one group delete")
        }
        XCTAssertEqual(group, "g-1")
        XCTAssertEqual(Set(ids), ["out", "in"])
        XCTAssertTrue(OfflineOverlay.apply(store.offlineQueue.pendingOperations, to: legs, nowISO: "2026-11-10T00:00:00Z").isEmpty,
                      "a fetch before the replay doesn't bring either leg back")

        let replayed = Recorder()
        store.offlineQueue.replayOperation = { op in
            if case .deleteTransferGroup(let g, _) = op.operation { replayed.add(g) }
        }
        await store.offlineQueue.processQueue()
        XCTAssertEqual(replayed.events, ["g-1"])
    }

    func test_Y8_groupDeleteWaitsForALegCreateThatMayBeOnTheServer() {
        var sent = PendingOperation(operation: .create(transferInput(account: "acc-1", type: "expense", group: "G").withClientId("leg-1")))
        sent.mayExistOnServer = true
        let unsent = PendingOperation(operation: .create(transferInput(account: "acc-2", type: "income", group: "G").withClientId("leg-2")))
        let delete = PendingOperation(operation: .deleteTransferGroup(groupId: "G", transactionIds: ["leg-1", "leg-2"]))

        let queue = OfflineQueue.coalesce([sent, unsent], adding: delete)

        XCTAssertEqual(queue.count, 2, "the unsent leg is cancelled, the sent one stays")
        XCTAssertEqual(queue[0].id, sent.id)
        guard case .deleteTransferGroup(_, let ids) = queue[1].operation else { return XCTFail("group delete last") }
        XCTAssertEqual(ids, ["leg-1"])
    }

    // MARK: Y9

    func test_Y9_createFinishingAfterSignOut_isNotAppliedToTheNextSession() async throws {
        let store = Fixture.onlineStore(persistence: persistence, script: RemoteScript(results: [RemoteFetchResult()]))
        let gate = Gate()
        let entered = Recorder()
        store.remote.createTransaction = { input in
            await entered.add("sent")
            await gate.wait()
            return Transaction.placeholder(for: input, nowISO: "2026-11-10T00:00:00Z")
        }
        let create = Task { try await store.addTransaction(Fixture.createInput()) }
        try await waitUntil { entered.count == 1 }

        store.resetForSignOut()
        await gate.open()

        do {
            _ = try await create.value
            XCTFail("must not land in the next session")
        } catch {
            XCTAssertTrue(error is SessionEndedError)
        }
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertFalse(store.offlineQueue.hasPending)
    }

    func test_Y9_journalPageFinishingAfterSignOut_isDropped() async throws {
        let journal = JournalViewModel()
        let gate = Gate()
        let entered = Recorder()
        journal.fetchPage = { _, _ in
            entered.add("page")
            await gate.wait()
            return [FinancialNote(id: "n-a", userId: "user-a", content: "A's note")]
        }
        journal.fetchAllTags = { ["tag-a"] }
        let load = Task { await journal.loadInitial() }
        try await waitUntil { entered.count == 1 }

        journal.reset()
        await gate.open()
        await load.value

        XCTAssertTrue(journal.notes.isEmpty)
        XCTAssertTrue(journal.allTags.isEmpty)
        XCTAssertFalse(journal.hasLoadedOnce)
    }
}

/// Y2: budget numbers refetch when partner spend, subscriptions or members
/// change — by content, not by row count — and on every explicit pull.
@MainActor
final class BudgetMetricsRefetchTests: XCTestCase {
    private var tempDir: URL?

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func spend(_ id: String, _ amount: Decimal) -> BudgetMath.ExternalSpendRow {
        BudgetMath.ExternalSpendRow(txId: id, amountNative: amount, currency: "RUB", txDate: "2026-11-27")
    }

    private func make() -> (BudgetMetricsStore, DataStore, Recorder) {
        let metrics = BudgetMetricsStore(persistenceURL: nil)
        metrics.autoRefreshEnabled = true
        metrics.sessionPresent = { true }
        let calls = Recorder()
        metrics.fetcher = { today, _ in
            await calls.add("fetch")
            return ServerBudgetMetricsResponse(version: 1, today: today, budgets: [])
        }
        let (persistence, dir) = Fixture.tempPersistence()
        tempDir = dir
        let store = DataStore(cache: persistence)
        store.isConnectedProvider = { true }
        store.profile = Profile(id: "u1", updatedAt: nil)
        store.budgets = [Budget(id: "b-1", userId: "u1", amount: 10_000_00, billingPeriod: .monthly, currency: "RUB")]
        store.budgetMembersByBudget = ["b-1": [
            BudgetMember(id: "m-1", budgetId: "b-1", userId: "u1", role: .owner),
            BudgetMember(id: "m-2", budgetId: "b-1", userId: "u2", role: .editor),
        ]]
        store.externalSpendByBudget = ["b-1": [spend("p-1", 500)]]
        return (metrics, store, calls)
    }

    func test_Y2_partnerSpendChange_refetchesEvenWithTheSameRowCount() async {
        let (metrics, store, calls) = make()
        await metrics.refresh(dataStore: store)
        await metrics.refresh(dataStore: store)
        XCTAssertEqual(calls.count, 1, "unchanged data → no refetch")

        // The partner's 500 ₽ became 1 500 ₽: same budget, same row count,
        // and nothing of this phone's own data moved.
        store.externalSpendByBudget = ["b-1": [spend("p-1", 1_500)]]
        await metrics.refresh(dataStore: store)

        XCTAssertEqual(calls.count, 2)
    }

    func test_Y2_subscriptionAndMemberChanges_refetch() async {
        let (metrics, store, calls) = make()
        await metrics.refresh(dataStore: store)

        store.subscriptions = [SubscriptionTracker(
            id: "s-1", userId: "u1", serviceName: "Кино", amount: 399_00, currency: "RUB",
            billingPeriod: .monthly, startDate: "2026-11-01", lastPaymentDate: nil,
            nextPaymentDate: "2026-12-01", categoryId: nil, reminderDays: 1, iconColor: nil,
            isActive: true, status: .active
        )]
        await metrics.refresh(dataStore: store)
        XCTAssertEqual(calls.count, 2, "subscription added")

        store.subscriptions[0].amount = 499_00
        await metrics.refresh(dataStore: store)
        XCTAssertEqual(calls.count, 3, "subscription edited")

        store.budgetMembersByBudget["b-1"]?[1].role = .viewer
        await metrics.refresh(dataStore: store)
        XCTAssertEqual(calls.count, 4, "member changed, count unchanged")
    }

    func test_Y2_pullToRefresh_alwaysAsksTheServer() async {
        let (metrics, store, calls) = make()
        await metrics.refresh(dataStore: store)
        await metrics.refresh(dataStore: store, force: true)
        await metrics.refresh(dataStore: store, force: true)
        XCTAssertEqual(calls.count, 3)
    }

    func test_Y2_answerForOlderPartnerSpend_isNotShownAsExact() throws {
        let server = try XCTUnwrap(BudgetServerParityTests.decodeServer().budgets.first)
        let id = BudgetServerParityTests.budgetId
        var input = BudgetMetricsResolver.Input(
            budgets: [BudgetServerParityTests.budget], transactions: [], subscriptions: [],
            categories: BudgetServerParityTests.allCategories, externalSpendByBudget: [:],
            memberCountByBudget: [id: 2], currencyContext: BudgetServerParityTests.context,
            generation: 7, now: BudgetServerParityTests.now, inputs: 1
        )
        let baseline = try XCTUnwrap(BudgetMetricsResolver.baseline(for: BudgetServerParityTests.budget, server: server, input: input))
        let snapshot = BudgetMetricsSnapshot(
            userId: BudgetServerParityTests.vladimir, day: "2026-11-17", fetchedAt: BudgetServerParityTests.now,
            generation: 7, budgets: [id: server], baselines: [id: baseline], inputs: 1
        )
        XCTAssertEqual(BudgetMetricsResolver.resolve(input, snapshot: snapshot, lastFetchFailed: false)[id]?.source, .server)

        input.inputs = 2  // partner spend moved since that answer
        XCTAssertNotEqual(BudgetMetricsResolver.resolve(input, snapshot: snapshot, lastFetchFailed: false)[id]?.source, .server)
    }

    func test_Y2_fingerprint_isContentNotCount() {
        let a = BudgetMetricsStore.inputsFingerprint(subscriptions: [], external: ["b": [spend("p", 500)]], members: [:])
        let b = BudgetMetricsStore.inputsFingerprint(subscriptions: [], external: ["b": [spend("p", 1_500)]], members: [:])
        let a2 = BudgetMetricsStore.inputsFingerprint(subscriptions: [], external: ["b": [spend("p", 500)]], members: [:])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a2)
    }
}

/// Y7: no snapshot → an explicit empty state, sample numbers only in the gallery.
final class WidgetEmptyStateTests: XCTestCase {
    func test_Y7_noSnapshot_isTheEmptyState_placeholderOnlyInTheGallery() {
        XCTAssertNil(SharedSnapshot.forDisplay(stored: nil, isPreview: false),
                     "after sign-out the home screen must not read «125 000 ₽ на 3 счетах»")
        XCTAssertEqual(SharedSnapshot.forDisplay(stored: nil, isPreview: true), SharedSnapshot.placeholder)
        var real = SharedSnapshot.placeholder
        real.dayKey = "2026-11-27"
        XCTAssertEqual(SharedSnapshot.forDisplay(stored: real, isPreview: false), real)
        XCTAssertEqual(SharedSnapshot.forDisplay(stored: real, isPreview: true), real, "real data wins in the gallery too")
    }
}

/// N5: the notification screen reads the server row, writes only the
/// user's changes (debounced), per user.
@MainActor
final class NotificationSettingsScreenTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "N5Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func make(user: String, server: NotificationSettings?, fetchFails: Bool = false) -> (NotificationSettingsViewModel, Recorder) {
        let writes = Recorder()
        let remote = NotificationSettingsViewModel.Remote(
            userId: { user },
            fetch: {
                if fetchFails { throw URLError(.notConnectedToInternet) }
                return server
            },
            save: { s in writes.add("save:\(s.enabled):\(s.budgetWarningPercent)") },
            createIfMissing: { s in writes.add("create:\(s.enabled)") }
        )
        return (NotificationSettingsViewModel(remote: remote, defaults: defaults, debounce: .milliseconds(30)), writes)
    }

    func test_N5_openingTheScreen_showsTheServerRowAndWritesNothing() async {
        var server = NotificationSettings.defaults
        server.enabled = false
        let (model, writes) = make(user: "user-a", server: server)

        await model.load()
        await model.flush()

        XCTAssertFalse(model.settings.enabled, "switched off on another device stays off")
        XCTAssertEqual(writes.events, [], "opening is not a write")
    }

    func test_N5_sliderDrag_isOneDebouncedWriteOfTheFinalValue() async throws {
        let (model, writes) = make(user: "user-a", server: .defaults)
        await model.load()

        for percent in stride(from: 75, through: 50, by: -5) {
            model.update { $0.budgetWarningPercent = percent }
        }
        try await waitUntil { writes.count >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        await model.flush()

        XCTAssertEqual(writes.events, ["save:true:50"], "80 → 50 used to send six unordered upserts")
    }

    func test_N5_settingsBelongToTheUserNotTheDevice() async {
        var off = NotificationSettings.defaults
        off.enabled = false
        let (a, _) = make(user: "user-a", server: off)
        await a.load()

        let (b, writes) = make(user: "user-b", server: nil, fetchFails: true)  // offline
        await b.load()

        XCTAssertTrue(b.settings.enabled, "B never gets A's settings on a shared phone")
        XCTAssertFalse(b.hasLocalValue)
        XCTAssertEqual(writes.events, [], "offline: nothing written")
        XCTAssertEqual(NotificationPreferencesCache.settings(userId: "user-a", defaults: defaults)?.enabled, false)
    }

    func test_N5_firstVisitWithoutARow_storesTheShownDefaultsInsertOnly() async {
        let (model, writes) = make(user: "user-a", server: nil)
        await model.load()
        XCTAssertEqual(writes.events, ["create:true"])
        XCTAssertTrue(model.isLoaded)
    }

    func test_N5_rowDecoding_isTolerant() throws {
        let json = #"{"enabled":false,"budget_warning_percent":85.0,"large_expense_threshold":null}"#
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.budgetWarningPercent, 85)
        XCTAssertEqual(decoded.largeExpenseThreshold, 0)
        XCTAssertTrue(decoded.budgetWarnings)
    }
}

/// N2: one weekly digest per device — never both the local Sunday one and
/// the server's Monday one; never while notifications are off.
final class WeeklyDigestSourceTests: XCTestCase {
    func test_N2_localDigest_onlyWhenTheServerDoesNotSendIt_andNotificationsAreOn() {
        XCTAssertFalse(NotificationManager.shouldScheduleLocalWeeklyDigest(
            notificationsEnabled: true, digestOptIn: true, serverPushRegistered: true
        ), "the server sends it to this device")
        XCTAssertTrue(NotificationManager.shouldScheduleLocalWeeklyDigest(
            notificationsEnabled: true, digestOptIn: true, serverPushRegistered: false
        ), "opted in, but no push channel to this device yet")
        XCTAssertFalse(NotificationManager.shouldScheduleLocalWeeklyDigest(
            notificationsEnabled: true, digestOptIn: false, serverPushRegistered: true
        ), "toggle OFF means no digest at all")
        XCTAssertFalse(NotificationManager.shouldScheduleLocalWeeklyDigest(
            notificationsEnabled: true, digestOptIn: false, serverPushRegistered: false
        ), "toggle OFF means no digest at all, push channel or not")
        XCTAssertFalse(NotificationManager.shouldScheduleLocalWeeklyDigest(
            notificationsEnabled: false, digestOptIn: true, serverPushRegistered: false
        ), "notifications switched off")
    }

    func test_N2_digestOptInCache_isPerUser() {
        let suite = "N2Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        NotificationPreferencesCache.storeDigestOptIn(true, userId: "user-a", defaults: defaults)
        XCTAssertTrue(NotificationPreferencesCache.digestOptIn(userId: "USER-A", defaults: defaults))
        XCTAssertFalse(NotificationPreferencesCache.digestOptIn(userId: "user-b", defaults: defaults))
    }
}

/// Fresh install regression (found in the 1.5.8 smoke test): the SDK throws
/// `sessionMissing` when nothing was ever stored, and the sign-in screen
/// showed «Сессия завершилась» to every new user.
@MainActor
final class SessionEndedNoticeColdStartTests: XCTestCase {
    func testFreshInstallDoesNotReportAnEndedSession() {
        XCTAssertFalse(AuthManager.shouldReportEndedSession(hadStoredSession: false, error: AuthError.sessionMissing))
    }

    func testDeadStoredSessionIsReported() {
        XCTAssertTrue(AuthManager.shouldReportEndedSession(hadStoredSession: true, error: AuthError.sessionMissing))
    }

    func testTransientErrorWithStoredSessionIsNotReported() {
        XCTAssertFalse(AuthManager.shouldReportEndedSession(hadStoredSession: true, error: URLError(.notConnectedToInternet)))
    }
}
