import Foundation
import Supabase
import os

// MARK: - Remote fetch

/// Everything one `DataStore` refresh reads from the server. A nil
/// collection means that fetch failed — the store keeps what it had.
struct RemoteFetchResult: Sendable {
    var accounts: [Account]?
    var transactions: [Transaction]?
    var categories: [Category]?
    var budgets: [Budget]?
    var subscriptions: [SubscriptionTracker]?
    /// nil = the profile fetch failed (keep the current one).
    var profile: Profile?
    var budgetMembersByBudget: [String: [BudgetMember]]?
    /// Always complete: a budget whose partner-spend RPC failed carries the
    /// last good value and is listed in `externalSpendIncomplete` (B5).
    var externalSpendByBudget: [String: [BudgetMath.ExternalSpendRow]] = [:]
    var externalSpendIncomplete: Set<String> = []
    /// nil = the partner-profile fetch failed.
    var profilesMap: [String: Profile]?
    /// Names of the user-visible collections that failed to load.
    var failures: [String] = []

    /// The two collections every balance depends on both arrived.
    var hasCoreData: Bool { accounts != nil && transactions != nil }
}

/// What the store had before the refresh — inputs to the partner-spend
/// fallback and to the profile-map merge.
struct RemoteFetchContext: Sendable {
    var previousExternalSpend: [String: [BudgetMath.ExternalSpendRow]]
    var previousBudgetMembers: [String: [BudgetMember]]
    var previousProfile: Profile?
}

/// The network side of `DataStore`, as closures so tests can drive load
/// ordering (single-flight, stale-result drops) and the online/queued
/// routing of writes without a server.
struct DataStoreRemote: Sendable {
    var fetchAll: @Sendable (RemoteFetchContext) async -> RemoteFetchResult
    var fetchTransactions: @Sendable () async throws -> [Transaction]
    var createTransaction: @Sendable (CreateTransactionInput) async throws -> Transaction
    var updateTransaction: @Sendable (_ id: String, UpdateTransactionInput) async throws -> Void
    var deleteTransaction: @Sendable (_ id: String) async throws -> Void
    /// Both legs of a manual transfer, one request (Y8).
    var deleteTransferGroup: @Sendable (_ groupId: String) async throws -> Void = {
        try await TransactionRepository().deleteTransferGroup(groupId: $0)
    }

    static let live = DataStoreRemote(
        fetchAll: { context in await LiveDataFetch.fetchAll(context) },
        fetchTransactions: { try await TransactionRepository().fetchAll() },
        createTransaction: { try await TransactionRepository().create($0) },
        updateTransaction: { try await TransactionRepository().update(id: $0, $1) },
        deleteTransaction: { try await TransactionRepository().delete(id: $0) }
    )
}

/// Production fetch. Two parallel phases instead of the old sequential
/// tail (budget_members → one RPC per shared budget in turn → profiles):
/// 1. the six core collections + budget members, all at once;
/// 2. partner spend for every shared budget and partner profiles, at once.
enum LiveDataFetch {
    private static func capture<T: Sendable>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    static func fetchAll(_ context: RemoteFetchContext) async -> RemoteFetchResult {
        let accountRepo = AccountRepository()
        let transactionRepo = TransactionRepository()
        let categoryRepo = CategoryRepository()
        let budgetRepo = BudgetRepository()
        let subscriptionRepo = SubscriptionTrackerRepository()
        let profileRepo = ProfileRepository()

        async let accountsFetch = capture { try await accountRepo.fetchAll() }
        async let txFetch = capture { try await transactionRepo.fetchAll() }
        async let catsFetch = capture { try await categoryRepo.fetchAll() }
        async let budgetsFetch = capture { try await budgetRepo.fetchAll() }
        async let subsFetch = capture { try await subscriptionRepo.fetchAll() }
        async let profileFetch = capture { try await profileRepo.fetch() }
        // Budget members (shared budgets) — RLS scopes rows to budgets the
        // user belongs to.
        async let membersFetch = capture { () async throws -> [BudgetMember] in
            try await SupabasePaging.all("budget_members") { count in
                SupabaseManager.shared.client
                    .from("budget_members")
                    .select(count: count)
            }
        }

        var failures: [String] = []
        func take<T>(_ r: Result<T, Error>, _ name: String, visible: Bool = true) -> T? {
            switch r {
            case .success(let value): return value
            case .failure(let error):
                AppLogger.data.warning("\(name, privacy: .public): \(error)")
                if visible { failures.append(name) }
                return nil
            }
        }
        // Into locals first: `take` mutates `failures`, never `result`.
        let accounts = take(await accountsFetch, "accounts")
        let transactions = take(await txFetch, "transactions")
        let categories = take(await catsFetch, "categories")
        let budgets = take(await budgetsFetch, "budgets")
        let subscriptions = take(await subsFetch, "subscriptions")
        let profile = take(await profileFetch, "profile", visible: false)
        let memberRows = take(await membersFetch, "budget_members", visible: false)

        var result = RemoteFetchResult()
        result.accounts = accounts
        result.transactions = transactions
        result.categories = categories
        result.budgets = budgets
        result.subscriptions = subscriptions
        result.profile = profile
        result.budgetMembersByBudget = memberRows.map { Dictionary(grouping: $0, by: \.budgetId) }

        // Phase 2 — both depend on phase-1 results, not on each other.
        let members = result.budgetMembersByBudget ?? context.previousBudgetMembers
        let sharedBudgetIds = members.filter { $0.value.count > 1 }.map(\.key)
        let currentUserId = (result.profile ?? context.previousProfile)?.id ?? ""
        // Hydrate partner profiles from transactions AND budget members —
        // a budget partner may have no visible transactions yet, but their
        // name/avatar must still resolve in the share sheet.
        let txUserIds = Set((result.transactions ?? []).map(\.userId))
        let memberUserIds = Set(members.values.flatMap { $0 }.map(\.userId))
        let otherUserIds = Array(txUserIds.union(memberUserIds).filter { $0 != currentUserId }).sorted()

        async let spendFetch = fetchExternalSpend(
            budgetIds: sharedBudgetIds, previous: context.previousExternalSpend
        )
        async let othersFetch = capture { try await profileRepo.fetchAll(ids: otherUserIds) }

        let spend = await spendFetch
        result.externalSpendByBudget = spend.rows
        result.externalSpendIncomplete = spend.incomplete

        if let others = take(await othersFetch, "profiles map", visible: false) {
            var map: [String: Profile] = [:]
            for p in others { map[p.id] = p }
            if let own = result.profile ?? context.previousProfile { map[own.id] = own }
            result.profilesMap = map
        }
        result.failures = failures
        return result
    }

    /// Partners' budget-relevant expenses invisible to this user's RLS, per
    /// shared budget, via `get_budget_member_expenses` — all budgets in
    /// parallel. A failed RPC keeps the budget's last good rows (marked
    /// incomplete) instead of silently dropping the partner's spending (B5).
    static func fetchExternalSpend(
        budgetIds: [String],
        previous: [String: [BudgetMath.ExternalSpendRow]],
        fetch: @escaping @Sendable (String) async throws -> [BudgetMath.ExternalSpendRow] = fetchBudgetMemberExpenses
    ) async -> (rows: [String: [BudgetMath.ExternalSpendRow]], incomplete: Set<String>) {
        guard !budgetIds.isEmpty else { return ([:], []) }

        var rows: [String: [BudgetMath.ExternalSpendRow]] = [:]
        var incomplete: Set<String> = []
        await withTaskGroup(of: (String, Result<[BudgetMath.ExternalSpendRow], Error>).self) { group in
            for budgetId in budgetIds {
                group.addTask {
                    (budgetId, await capture { try await fetch(budgetId) })
                }
            }
            for await (budgetId, r) in group {
                switch r {
                case .success(let fetched):
                    if !fetched.isEmpty { rows[budgetId] = fetched }
                case .failure(let error):
                    AppLogger.data.warning("external budget spend (\(budgetId, privacy: .public)): \(error)")
                    incomplete.insert(budgetId)
                    if let last = previous[budgetId] { rows[budgetId] = last }
                }
            }
        }
        return (rows, incomplete)
    }

    /// One shared budget's partner spend. RPC results are capped at
    /// max-rows exactly like table reads; v2 of the function (migration
    /// 20260910120000) returns tx_id and orders by (date, id) so it pages
    /// safely.
    @Sendable
    static func fetchBudgetMemberExpenses(_ budgetId: String) async throws -> [BudgetMath.ExternalSpendRow] {
        struct Params: Encodable, Sendable { let p_budget_id: String }
        return try await SupabasePaging.all("get_budget_member_expenses", tiebreak: ["tx_id"]) { count in
            try SupabaseManager.shared.client
                .rpc("get_budget_member_expenses", params: Params(p_budget_id: budgetId), count: count)
        }
    }
}

// MARK: - Offline overlay

/// Re-applies queued-but-unsynced operations onto a freshly fetched list so
/// not-yet-synced placeholders survive the fetch overwrite. Pure — runs off
/// the main actor during a load.
enum OfflineOverlay {
    /// `deadLetters` (Y6) are applied first — they are older than anything
    /// still queued — and their rows are marked `Transaction.unsyncedStatus`
    /// ("не сохранено") instead of pending: the server refused them, the
    /// user decides in Settings whether to retry or discard. A refused
    /// delete leaves the row visible (the server still has it), marked.
    static func apply(
        _ operations: [PendingOperation],
        deadLetters: [PendingOperation] = [],
        to fetched: [Transaction],
        nowISO: String
    ) -> [Transaction] {
        guard !operations.isEmpty || !deadLetters.isEmpty else { return fetched }
        var transactions = fetched
        for op in deadLetters {
            apply(op, to: &transactions, nowISO: nowISO, unsynced: true)
        }
        for op in operations {
            apply(op, to: &transactions, nowISO: nowISO, unsynced: false)
        }
        return transactions
    }

    private static func apply(
        _ op: PendingOperation,
        to transactions: inout [Transaction],
        nowISO: String,
        unsynced: Bool
    ) {
        func mark(_ indices: [Int]) {
            guard unsynced else { return }
            for i in indices { transactions[i].status = Transaction.unsyncedStatus }
        }
        switch op.operation {
        case .create(let input):
            // The server row carries the client id (plain INSERT `id`,
            // RPC `p_id`) — once it is there the placeholder must not be
            // shown on top of it.
            guard let clientId = input.id,
                  !transactions.contains(where: { $0.id == clientId }) else { return }
            var rows = input.routesToAutoTransferRPC
                ? Transaction.placeholderTriplet(for: input, nowISO: nowISO)
                : [Transaction.placeholder(for: input, nowISO: nowISO)]
            if unsynced {
                for i in rows.indices { rows[i].status = Transaction.unsyncedStatus }
            }
            transactions.insert(contentsOf: rows, at: 0)
        case .update(let txId, let input):
            if let idx = transactions.firstIndex(where: { $0.id == txId }) {
                let tx = transactions[idx]
                transactions[idx] = tx.applying(input)
                mark([idx])
                if input.useAutoTransferUpdate, let groupId = tx.autoTransferGroupId {
                    patchAutoTransferLegs(in: &transactions, groupId: groupId, expenseId: txId, input: input)
                    mark(transactions.indices.filter { transactions[$0].autoTransferGroupId == groupId })
                }
            }
        case .delete(let txId):
            guard let idx = transactions.firstIndex(where: { $0.id == txId }) else { return }
            let groupId = transactions[idx].autoTransferGroupId
            if unsynced {
                mark(transactions.indices.filter {
                    groupId != nil ? transactions[$0].autoTransferGroupId == groupId : $0 == idx
                })
            } else if let groupId {
                transactions.removeAll { $0.autoTransferGroupId == groupId }
            } else {
                transactions.remove(at: idx)
            }
        case .deleteTransferGroup(let groupId, _):
            let isLeg: (Transaction) -> Bool = { $0.isManualTransferLeg(ofGroup: groupId) }
            if unsynced {
                mark(transactions.indices.filter { isLeg(transactions[$0]) })
            } else {
                transactions.removeAll(where: isLeg)
            }
        }
    }

    /// Local mirror of `update_expense_with_auto_transfer`: when the main
    /// expense of a triplet is edited offline, both transfer legs move too —
    /// otherwise the source-account balance would be stale until the queue
    /// drains. Out-leg takes `source_amount` (its own currency, 11-arg
    /// overload semantics), in-leg takes `amount`.
    static func patchAutoTransferLegs(
        in transactions: inout [Transaction],
        groupId: String,
        expenseId: String,
        input: UpdateTransactionInput
    ) {
        for idx in transactions.indices {
            let leg = transactions[idx]
            guard leg.autoTransferGroupId == groupId,
                  leg.id != expenseId,
                  leg.transferGroupId != nil else { continue }
            let legAmount = leg.type == .expense
                ? (input.source_amount ?? input.amount)
                : input.amount
            let legDescription = input.description.map {
                "Авто-перевод: " + ($0.isEmpty ? "расход" : $0)
            }
            transactions[idx] = leg.applying(UpdateTransactionInput(
                amount: legAmount,
                amount_native: legAmount,
                date: input.date,
                description: legDescription
            ))
        }
    }
}

// MARK: - Change detection

/// Skip-equal-writes support. Most models are not `Equatable` (and can't
/// get synthesized conformance outside their own files), so equality is
/// decided on the cache encoding — the same bytes that go to disk, so a
/// changed collection costs one encode, and an unchanged one costs no
/// observable write and no disk write. Runs off the main actor.
enum ContentComparison {
    /// Encoded `new` when it differs from `old`; nil when equal. When
    /// encoding fails the value is reported as changed with empty bytes
    /// (assign it, but don't cache).
    static func changedEncoding<T: Encodable>(_ new: T, comparedTo old: T) -> Data? {
        let encoder = PersistenceManager.makeEncoder()
        guard let newData = try? encoder.encode(new) else { return Data() }
        let oldData = try? encoder.encode(old)
        return newData == oldData ? nil : newData
    }

    static func isEqual<T: Encodable>(_ a: T, _ b: T) -> Bool {
        changedEncoding(a, comparedTo: b) == nil
    }
}

/// The store's observable data at one instant, captured on the main actor.
struct DataStoreContent: Sendable {
    var accounts: [Account]
    var transactions: [Transaction]
    var categories: [Category]
    var budgets: [Budget]
    var subscriptions: [SubscriptionTracker]
    var profile: Profile?
    var profilesMap: [String: Profile]
    var budgetMembersByBudget: [String: [BudgetMember]]
    var externalSpendByBudget: [String: [BudgetMath.ExternalSpendRow]]
}

/// Which collections a refresh actually changed, with the cache bytes of
/// the persisted ones. nil = unchanged (or not fetched).
struct DataStoreChangeSet: Sendable {
    struct Changed<T: Sendable>: Sendable {
        let value: T
        /// Cache-file bytes; empty when encoding failed.
        let encoded: Data
    }
    var accounts: Changed<[Account]>?
    var transactions: Changed<[Transaction]>?
    var categories: Changed<[Category]>?
    var budgets: Changed<[Budget]>?
    var subscriptions: Changed<[SubscriptionTracker]>?
    var profile: Changed<Profile>?
    var profilesMap: [String: Profile]?
    var budgetMembersByBudget: [String: [BudgetMember]]?
    var externalSpendByBudget: [String: [BudgetMath.ExternalSpendRow]]?

    /// Inputs of `rebuildCaches()` changed.
    var affectsDerivedCaches: Bool {
        accounts != nil || transactions != nil || categories != nil || profile != nil
    }

    var isEmpty: Bool {
        accounts == nil && transactions == nil && categories == nil && budgets == nil
            && subscriptions == nil && profile == nil && profilesMap == nil
            && budgetMembersByBudget == nil && externalSpendByBudget == nil
    }

    static func compute(
        fetched: RemoteFetchResult,
        overlay pendingOps: [PendingOperation],
        deadLetters: [PendingOperation] = [],
        current: DataStoreContent,
        nowISO: String
    ) -> DataStoreChangeSet {
        func diff<T: Encodable & Sendable>(_ new: T?, _ old: T) -> Changed<T>? {
            guard let new, let bytes = ContentComparison.changedEncoding(new, comparedTo: old) else { return nil }
            return Changed(value: new, encoded: bytes)
        }
        var set = DataStoreChangeSet()
        set.accounts = diff(fetched.accounts, current.accounts)
        set.transactions = diff(
            fetched.transactions.map {
                OfflineOverlay.apply(pendingOps, deadLetters: deadLetters, to: $0, nowISO: nowISO)
            },
            current.transactions
        )
        set.categories = diff(fetched.categories, current.categories)
        set.budgets = diff(fetched.budgets, current.budgets)
        set.subscriptions = diff(fetched.subscriptions, current.subscriptions)
        if let profile = fetched.profile {
            let old: Profile? = current.profile
            if let bytes = ContentComparison.changedEncoding(Optional(profile), comparedTo: old) {
                set.profile = Changed(value: profile, encoded: bytes)
            }
        }
        if let map = fetched.profilesMap, !ContentComparison.isEqual(map, current.profilesMap) {
            set.profilesMap = map
        }
        if let members = fetched.budgetMembersByBudget,
           !ContentComparison.isEqual(members, current.budgetMembersByBudget) {
            set.budgetMembersByBudget = members
        }
        if !ContentComparison.isEqual(fetched.externalSpendByBudget, current.externalSpendByBudget) {
            set.externalSpendByBudget = fetched.externalSpendByBudget
        }
        return set
    }
}
