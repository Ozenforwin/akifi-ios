import Foundation
import os

/// Aggregated income / expense for a single yyyy-MM bucket, in the user's
/// **base currency** (kopecks). Built once per `rebuildCaches()` and read
/// by analytics widgets via `DataStore.recentMonthlyAggregates(...)`.
///
/// Contract: net cashflow only. Transactions of type `.transfer` (or any row
/// carrying a `transferGroupId`) are excluded — they move money between the
/// user's own accounts and would double-count or cancel out depending on
/// account scope.
struct MonthlyAggregate: Sendable, Equatable {
    let monthKey: String       // "yyyy-MM"
    let income: Int64          // base currency, kopecks
    let expense: Int64         // base currency, kopecks
    var net: Int64 { income - expense }
}

/// A write that finished after the user signed out: its result belongs to
/// the previous session and was not applied locally (Y9).
struct SessionEndedError: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "auth.sessionEnded.title") }
}

@Observable @MainActor
final class DataStore {
    /// Every account the user can see — money accounts, «Долги» (debt)
    /// accounts and types this build does not know. The storage behind
    /// `accounts`; use it ONLY to resolve an id (`account(withId:)`: a
    /// transaction row, a transfer leg) and in the debt flows. Lists,
    /// pickers and totals read `accounts`. `DebtExclusionGuardTests` fails
    /// when a new file starts reading this.
    var allAccounts: [Account] = [] {
        didSet {
            let money = allAccounts.moneyAccounts
            // Skip-equal: an unchanged money subset invalidates no view.
            if money != accounts { accounts = money }
        }
    }
    /// Spendable money accounts (`AccountType.isMoney`) — the ONE source of
    /// every account list, picker and total: the carousel, "всего на
    /// счетах", expense / income / transfer / «Оплачено с» targets,
    /// budgets, subscriptions, deposits, savings, sharing, the widget, the
    /// assistant context, analytics and report filters. A debt is not
    /// money the user can spend (contract §A7), so it is never here.
    private(set) var accounts: [Account] = []
    var transactions: [Transaction] = []
    var categories: [Category] = []
    var isLoading = false

    /// A problem the user must see — shown by the banner in `MainTabView`.
    /// Before this, `error` was written and read by nobody: a partial load
    /// looked complete and a failed delete looked like it worked.
    struct Issue: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Some collections failed to refresh; cached values are shown.
            case load
            /// A user action (delete, …) failed and was not applied.
            case mutation
            /// The server refused queued writes for good (dead letters,
            /// Y6) — they stay on the device as «не сохранено».
            case unsynced
        }
        let id = UUID()
        let kind: Kind
        let message: String
    }
    private(set) var issue: Issue?

    /// Localized text of the current issue.
    var error: String? { issue?.message }

    func dismissIssue() {
        issue = nil
    }

    func reportIssue(_ kind: Issue.Kind, message: String) {
        issue = Issue(kind: kind, message: message)
    }

    /// Optional back-reference to `CurrencyManager` — injected by
    /// `AppViewModel` so that `rebuildCaches()` can refresh the widget
    /// snapshot with correct FX rates.
    var currencyManager: CurrencyManager?

    /// A recently-auto-matched subscription payment, surfaced as a banner in the UI.
    /// When non-nil, the root view shows an undo-banner; it auto-dismisses after 5 s.
    var pendingAutoMatch: PendingAutoMatch?

    // MARK: - Derived caches
    //
    // All derived per-account / per-category caches sit behind ONE observed
    // revision. `rebuildCaches()` compares each rebuilt cache with the old
    // one and bumps the revision only when something actually changed, so a
    // refresh that changes nothing re-renders nothing (P2). Readers
    // (`balance(for:)`, `category(for:)`, `accountIncome`, …) touch
    // `derivedRevision` to register the dependency.
    private(set) var derivedRevision: UInt64 = 0
    @ObservationIgnored private var balanceCache: [String: Int64] = [:]
    @ObservationIgnored private var categoryIndex: [String: Category] = [:]
    @ObservationIgnored private var accountIncomeStorage: [String: Int64] = [:]
    @ObservationIgnored private var accountExpenseStorage: [String: Int64] = [:]

    /// Pre-computed per-account income for cards (base currency, kopecks).
    var accountIncome: [String: Int64] {
        _ = derivedRevision
        return accountIncomeStorage
    }

    /// Pre-computed per-account expense for cards (base currency, kopecks).
    var accountExpense: [String: Int64] {
        _ = derivedRevision
        return accountExpenseStorage
    }

    // MARK: - FX context cache
    //
    // Analytics-heavy screens (cashflow, category breakdown, monthly summary,
    // daily-limit widget) call `amountInBase(_:)` thousands of times per
    // render. Rebuilding `[accountId: Account]` and `[String: Decimal]` on
    // every call was the dominant cost — for ~2 000 transactions and 6
    // analytics passes that's tens of thousands of dictionary allocations.
    //
    // We cache them as `@ObservationIgnored` so mutations don't trigger
    // SwiftUI redraws (the cache is derived state — `accounts` /
    // `currencyManager.rates` are the canonical sources). Keep these in
    // sync via `rebuildCurrencyContext()`.
    @ObservationIgnored private var accountsById: [String: Account] = [:]
    @ObservationIgnored private var fxRatesDecimal: [String: Decimal] = [:]
    @ObservationIgnored private var baseCurrencyCode: String = "RUB"

    // MARK: - Monthly aggregate cache (analytics)
    //
    // Pre-bucketed income/expense per yyyy-MM, in base currency (kopecks).
    // Built eagerly in `rebuildCaches()` because the cost is trivial
    // (O(transactions)) and analytics widgets hit these on every render
    // / period change. Power-users have 5-15 accounts → per-account map
    // stays under a few KB.
    //
    // Excludes `.transfer` rows and anything tagged with `transferGroupId`
    // (cross-leg moves between user's own accounts) so the totals reflect
    // true net cashflow.
    @ObservationIgnored private(set) var monthlyAggregates: [String: MonthlyAggregate] = [:]
    @ObservationIgnored private(set) var monthlyAggregatesByAccount: [String: [String: MonthlyAggregate]] = [:]

    /// Monotonic counter bumped at the end of every `rebuildCaches()` and on
    /// `currencyContextDidChange()`. Downstream `@Observable` view-states
    /// (e.g. `AnalyticsTabState`) compare this token in their cache key —
    /// any change forces re-derivation without needing per-property KVO.
    @ObservationIgnored private(set) var txGenerationToken: UInt64 = 0

    private let subscriptionRepo = SubscriptionTrackerRepository()

    var budgets: [Budget] = []
    var subscriptions: [SubscriptionTracker] = []
    var profile: Profile?
    var profilesMap: [String: Profile] = [:]
    /// Members of shared budgets, keyed by budget id. Single-member budgets
    /// (just the owner) render no avatar stack.
    var budgetMembersByBudget: [String: [BudgetMember]] = [:]
    /// Partners' budget-relevant expenses invisible to this user's RLS
    /// (paid from accounts not shared with them), keyed by budget id.
    /// Added on top of the local spent so a shared budget's progress bar
    /// reflects EVERYONE's spending, not just what this device can see.
    var externalSpendByBudget: [String: [BudgetMath.ExternalSpendRow]] = [:]
    /// Shared budgets whose partner spend failed to refresh on the last
    /// load: `externalSpendByBudget` holds the previous good rows for them
    /// (B5). Budget views can mark these numbers as possibly incomplete.
    private(set) var externalSpendIncompleteBudgetIds: Set<String> = []

    private let cache: PersistenceManager
    let offlineQueue: OfflineQueue

    /// Connectivity seam — tests override this instead of fighting the
    /// NWPathMonitor singleton. Production always reads NetworkMonitor.
    @ObservationIgnored var isConnectedProvider: @MainActor () -> Bool = {
        NetworkMonitor.shared.isConnected
    }
    private var isOnline: Bool { isConnectedProvider() }

    /// Session seam (Y2). With no valid session the SDK silently sends the
    /// anon key: reads come back `[]`, updates and deletes match nothing and
    /// "succeed". So no session = offline: keep the cache, never cache
    /// what came back, never replay the queue.
    @ObservationIgnored var sessionValidator: @MainActor () async -> Bool = {
        await SupabaseManager.shared.hasValidSession()
    }
    /// Cheap re-check after a long fetch: a session still exists AND its
    /// access token is still valid (Y5) — a token that ran out mid-fetch
    /// with a failed refresh sent the rest of the requests as anon.
    @ObservationIgnored var localSessionPresent: @MainActor () -> Bool = {
        SupabaseManager.shared.hasUnexpiredLocalSession
    }
    /// The signed-in user per the SDK, synchronously — owner of what this
    /// store caches (Y3). nil without a session.
    @ObservationIgnored var currentUserIdProvider: @MainActor () -> String? = {
        SupabaseManager.shared.client.auth.currentSession?.user.id.uuidString.lowercased()
    }
    /// Online, yet the SDK holds no session at all: it dropped it (dead
    /// refresh token) and the auth event was missed. `AppViewModel` routes
    /// this into the forced sign-out (Y1) — otherwise every write would
    /// queue forever behind a session that will never come back.
    @ObservationIgnored var onSessionMissing: (@MainActor () -> Void)?
    /// The user whose id is in `cache_owner.json` this session (Y3).
    @ObservationIgnored private var taggedCacheOwner: String?
    /// Network seam — see `DataStoreRemote`.
    @ObservationIgnored var remote: DataStoreRemote = .live

    // MARK: - Load coordination (Y6)

    /// The one load in flight. Concurrent `loadAll()` callers join it and
    /// ask for a re-run instead of racing it — the last finisher used to
    /// win, so a refresh that started before a save could land after it
    /// and bring a deleted row back.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadRerunRequested = false
    /// Bumped by every local mutation of `transactions` / `subscriptions`.
    /// A fetch that started before the latest mutation is stale for those
    /// collections and is dropped (and re-run).
    @ObservationIgnored private(set) var mutationGeneration: UInt64 = 0
    /// Bumped on sign-out: everything still in flight for the previous
    /// user is discarded when it lands.
    @ObservationIgnored private(set) var sessionEpoch: UInt64 = 0
    @ObservationIgnored private var hasLoadedCache = false
    /// When the last refresh that delivered accounts AND transactions from
    /// the server finished. nil = what's on screen is cache only. Net-worth
    /// snapshots are written only on top of fresh data (Y8).
    @ObservationIgnored private(set) var lastCompleteLoadAt: Date?
    @ObservationIgnored private var widgetSnapshotTask: Task<Void, Never>?
    /// The Home card's eye toggles, as the last widget snapshot saw them.
    @ObservationIgnored private var widgetHiddenBalanceIds: Set<String> = HiddenBalances.ids()
    @ObservationIgnored private var hiddenBalancesObserver: NotificationObservation?

    init(cache: PersistenceManager = .shared) {
        self.cache = cache
        self.offlineQueue = OfflineQueue(persistence: cache)
        offlineQueue.onDeadLettered = { [weak self] ops in
            self?.handleDeadLettered(ops)
        }
        // Hiding a balance on the Home card is a defaults write, not a data
        // change: the «Счёт» widget learns it here (same debounce).
        hiddenBalancesObserver = NotificationObservation(name: UserDefaults.didChangeNotification) { [weak self] in
            self?.hiddenBalancesMayHaveChanged()
        }
    }

    private func hiddenBalancesMayHaveChanged() {
        let ids = HiddenBalances.ids()
        guard ids != widgetHiddenBalanceIds else { return }
        widgetHiddenBalanceIds = ids
        writeWidgetSnapshot()
    }

    // MARK: - Auto-match settings key
    static let autoMatchEnabledKey = "subscriptionsAutoMatchEnabled"

    /// Something to render — cached or fresh.
    var hasDisplayableData: Bool {
        !allAccounts.isEmpty || !transactions.isEmpty
    }

    /// Refreshes everything from the server. Single-flight: a call while a
    /// load is running waits for it and makes it run once more, so every
    /// caller returns with data at least as fresh as its own call.
    func loadAll() async {
        if let running = loadTask {
            loadRerunRequested = true
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.loadRerunRequested = false
                await self.performLoad()
            } while self.loadRerunRequested
            // No suspension between the loop exit and this line: a caller
            // arriving now starts a fresh load instead of joining a
            // finished one.
            self.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    /// Decodes the on-disk cache once (off the main thread) and shows it.
    /// Never overwrites data already in memory. Returns whether anything
    /// is displayable afterwards — `AppViewModel` lifts the splash on it.
    @discardableResult
    func loadCachedDataIfNeeded() async -> Bool {
        guard !hasLoadedCache else { return hasDisplayableData }
        hasLoadedCache = true
        let epoch = sessionEpoch
        var snapshot = await cache.loadDataSnapshot()
        guard epoch == sessionEpoch else { return false }

        // Y3: only the signed-in user's own cache is ever shown. A cache
        // left by someone else (sign-out interrupted, session dropped by
        // the SDK) — or one nobody can vouch for — is wiped, not decoded
        // into the UI and the widget.
        let user = currentUserIdProvider()
        if snapshot.hasAnyContent, user == nil || snapshot.owner != user {
            AppLogger.data.warning("Offline cache belongs to another user — discarding it")
            cache.clearAll(preservingQueue: true)
            snapshot = CachedDataSnapshot()
        }
        tagCacheOwnerIfNeeded()

        var changed = false
        if allAccounts.isEmpty, let v = snapshot.accounts, !v.isEmpty { allAccounts = v; changed = true }
        if transactions.isEmpty {
            // Cache writes are asynchronous; the queue file is written
            // synchronously. Re-apply the queue so an entry whose cache write
            // didn't land before the app died still shows (idempotent for
            // the ones that did).
            let restored = OfflineOverlay.apply(
                offlineQueue.pendingOperations,
                deadLetters: offlineQueue.deadLetterOperations,
                to: snapshot.transactions ?? [],
                nowISO: AppDateFormatters.nowTimestamp()
            )
            if !restored.isEmpty { transactions = restored; changed = true }
        }
        if categories.isEmpty, let v = snapshot.categories, !v.isEmpty { categories = v; changed = true }
        if budgets.isEmpty, let v = snapshot.budgets, !v.isEmpty { budgets = v; changed = true }
        if subscriptions.isEmpty, let v = snapshot.subscriptions, !v.isEmpty { subscriptions = v; changed = true }
        if profile == nil, let p = snapshot.profile { profile = p; changed = true }
        if changed { rebuildCaches() }
        return hasDisplayableData
    }

    private func performLoad() async {
        let epoch = sessionEpoch
        await loadCachedDataIfNeeded()
        guard epoch == sessionEpoch else { return }

        if !isLoading { isLoading = true }
        defer {
            if epoch == sessionEpoch, isLoading { isLoading = false }
        }

        // Offline or no usable session: cached content is the app. Don't
        // attempt fetches that can only fail (or, as anon, "succeed" with
        // nothing), don't surface an error — the offline banner tells it.
        guard await canReachServer(), epoch == sessionEpoch else {
            if epoch == sessionEpoch { writeWidgetSnapshot() }
            return
        }

        // Sync queued writes first so the fetch below already contains them.
        if offlineQueue.hasPending {
            await offlineQueue.processQueue()
            guard epoch == sessionEpoch else { return }
        }

        let mutationMark = mutationGeneration
        let fetched = await remote.fetchAll(RemoteFetchContext(
            previousExternalSpend: externalSpendByBudget,
            previousBudgetMembers: budgetMembersByBudget,
            previousProfile: profile
        ))
        guard epoch == sessionEpoch else { return }

        // The session vanished mid-flight (signed out elsewhere, refresh
        // failed): later requests went out as anon and came back empty.
        // Nothing from this round can be trusted.
        guard localSessionPresent() else {
            AppLogger.data.warning("Session lost during load — discarding fetched data")
            return
        }

        // Diff against what's on screen off the main actor; equal
        // collections are neither reassigned nor rewritten to disk.
        let pendingOps = offlineQueue.pendingOperations
        let deadLetters = offlineQueue.deadLetterOperations
        let current = content
        let nowISO = AppDateFormatters.nowTimestamp()
        var changes = await Task.detached(priority: .userInitiated) {
            DataStoreChangeSet.compute(
                fetched: fetched, overlay: pendingOps, deadLetters: deadLetters,
                current: current, nowISO: nowISO
            )
        }.value
        guard epoch == sessionEpoch else { return }

        let freshForMutations = mutationGeneration == mutationMark
        if !freshForMutations {
            // Local edits landed while we were fetching: this transaction
            // and subscription list predate them. Keep the local state and
            // fetch again.
            changes.transactions = nil
            changes.subscriptions = nil
            loadRerunRequested = true
        }

        apply(changes)
        if fetched.externalSpendIncomplete != externalSpendIncompleteBudgetIds {
            externalSpendIncompleteBudgetIds = fetched.externalSpendIncomplete
        }
        if fetched.hasCoreData && freshForMutations {
            lastCompleteLoadAt = Date()
        }

        if fetched.failures.isEmpty {
            if issue?.kind == .load { issue = nil }
        } else if isOnline {
            // isOnline re-check: connectivity lost mid-load — cached data is
            // showing, an error would only duplicate the offline banner.
            AppLogger.data.warning("Load completed with errors: \(fetched.failures.joined(separator: ", "), privacy: .public)")
            if issue?.kind != .load {
                reportIssue(.load, message: String(localized: "sync.error.partialLoad"))
            }
        }
        // Widget "today" figures move with the clock, not only with data.
        writeWidgetSnapshot()
    }

    /// One synchronous batch: every changed collection is assigned exactly
    /// once, then derived caches are rebuilt once — one render pass.
    private func apply(_ changes: DataStoreChangeSet) {
        guard !changes.isEmpty else { return }
        if let c = changes.accounts {
            allAccounts = c.value
            persist(c.encoded, PersistenceManager.Filename.accounts)
        }
        if let c = changes.transactions {
            transactions = c.value
            persist(c.encoded, PersistenceManager.Filename.transactions)
        }
        if let c = changes.categories {
            categories = c.value
            persist(c.encoded, PersistenceManager.Filename.categories)
        }
        if let c = changes.budgets {
            budgets = c.value
            persist(c.encoded, PersistenceManager.Filename.budgets)
        }
        if let c = changes.subscriptions {
            subscriptions = c.value
            persist(c.encoded, PersistenceManager.Filename.subscriptions)
        }
        if let c = changes.profile {
            profile = c.value
            persist(c.encoded, PersistenceManager.Filename.profile)
        }
        if let map = changes.profilesMap { profilesMap = map }
        if let members = changes.budgetMembersByBudget { budgetMembersByBudget = members }
        if let spend = changes.externalSpendByBudget { externalSpendByBudget = spend }
        if changes.affectsDerivedCaches { rebuildCaches() }
    }

    private func persist(_ encoded: Data, _ filename: String) {
        guard !encoded.isEmpty else { return }
        tagCacheOwnerIfNeeded()
        cache.writeInBackground(encoded, filename: filename)
    }

    /// Makes sure the on-disk cache is tagged with the signed-in user
    /// before anything of theirs goes into it (Y3). A cache tagged with
    /// someone else (or nobody, with data in it) is wiped first — files of
    /// two users must never mix.
    private func tagCacheOwnerIfNeeded() {
        guard let user = currentUserIdProvider(), taggedCacheOwner != user else { return }
        let owner = PersistenceManager.cacheOwner(
            tag: cache.loadCacheOwner(), cachedProfileId: cache.loadProfile()?.id
        )
        if owner != user { cache.clearAll(preservingQueue: true) }
        cache.saveCacheOwner(user)
        taggedCacheOwner = user
    }

    private var content: DataStoreContent {
        DataStoreContent(
            accounts: allAccounts,
            transactions: transactions,
            categories: categories,
            budgets: budgets,
            subscriptions: subscriptions,
            profile: profile,
            profilesMap: profilesMap,
            budgetMembersByBudget: budgetMembersByBudget,
            externalSpendByBudget: externalSpendByBudget
        )
    }

    /// Online AND a valid session (Y2).
    private func canReachServer() async -> Bool {
        guard isOnline else { return false }
        if await sessionValidator() { return true }
        // No session object at all (not merely an expired token whose
        // refresh failed): the SDK dropped it for good. Y1 safety net in
        // case the `.signedOut` event was missed.
        if isOnline, !localSessionPresent(), currentUserIdProvider() == nil {
            onSessionMissing?()
        }
        return false
    }

    /// Replays the offline queue and refreshes transactions afterwards so
    /// placeholders get swapped for the server rows. Triggered by the
    /// reconnect hook in `MainTabView` and safe to call at any time —
    /// no-ops when offline, without a session, idle, or already processing.
    func syncPendingOperations() async {
        guard isOnline, offlineQueue.hasPending, !offlineQueue.isProcessing else { return }
        guard await sessionValidator() else { return }
        await offlineQueue.processQueue()
        await refreshTransactions()
    }

    /// Refetches only transactions, under the same rules as `loadAll()`:
    /// joins a running full load, drops a result that predates a local
    /// mutation, skips an unchanged result.
    func refreshTransactions() async {
        if let running = loadTask {
            loadRerunRequested = true
            await running.value
            return
        }
        guard await canReachServer() else { return }
        for _ in 0..<3 {
            let epoch = sessionEpoch
            let mark = mutationGeneration
            let fetched: [Transaction]
            do {
                fetched = try await remote.fetchTransactions()
            } catch {
                AppLogger.data.warning("Transaction refresh failed: \(error)")
                return
            }
            guard epoch == sessionEpoch, localSessionPresent() else { return }
            let pendingOps = offlineQueue.pendingOperations
            let deadLetters = offlineQueue.deadLetterOperations
            let current = transactions
            let nowISO = AppDateFormatters.nowTimestamp()
            let changed = await Task.detached(priority: .userInitiated) { () -> DataStoreChangeSet.Changed<[Transaction]>? in
                let final = OfflineOverlay.apply(pendingOps, deadLetters: deadLetters, to: fetched, nowISO: nowISO)
                guard let bytes = ContentComparison.changedEncoding(final, comparedTo: current) else { return nil }
                return DataStoreChangeSet.Changed(value: final, encoded: bytes)
            }.value
            guard epoch == sessionEpoch else { return }
            // A local edit landed during the fetch — this list is stale.
            guard mark == mutationGeneration else { continue }
            if let changed {
                transactions = changed.value
                persist(changed.encoded, PersistenceManager.Filename.transactions)
                rebuildCaches()
                writeWidgetSnapshot()
            }
            return
        }
    }

    /// Re-applies queued-but-unsynced operations onto `transactions` after
    /// a network fetch replaced the array. Without this, a fetch that lands
    /// while ops are still queued (flaky connectivity, halted replay round)
    /// would make the user's offline entries vanish from the UI.
    /// Internal (not private) so tests can exercise the overlay directly.
    func applyPendingOverlay() {
        guard offlineQueue.hasUnsynced else { return }
        transactions = OfflineOverlay.apply(
            offlineQueue.pendingOperations,
            deadLetters: offlineQueue.deadLetterOperations,
            to: transactions,
            nowISO: AppDateFormatters.nowTimestamp()
        )
    }

    // MARK: - Refused writes (Y6)

    /// The server refused queued writes for good: say so right away, and
    /// mark their rows «не сохранено» — a refused create must not silently
    /// drop out of the list and the balance on the next refresh.
    private func handleDeadLettered(_ ops: [PendingOperation]) {
        guard !ops.isEmpty else { return }
        let targets = Set(ops.flatMap(\.targetTransactionIds))
        // A triplet's legs go with its expense.
        let tripletGroups = Set(transactions.filter { targets.contains($0.id) }.compactMap(\.autoTransferGroupId))
        var transferGroups: [String] = []
        for op in ops {
            if case .deleteTransferGroup(let groupId, _) = op.operation { transferGroups.append(groupId) }
        }
        var touched = false
        for i in transactions.indices {
            let tx = transactions[i]
            let hit = targets.contains(tx.id)
                || (tx.autoTransferGroupId.map(tripletGroups.contains) ?? false)
                || transferGroups.contains { tx.isManualTransferLeg(ofGroup: $0) }
            if hit, !tx.isUnsynced {
                transactions[i].status = Transaction.unsyncedStatus
                touched = true
            }
        }
        if touched {
            noteLocalMutation()
            persistTransactions()
            rebuildCaches()
        }
        reportIssue(.unsynced, message: String(
            format: String(localized: "sync.error.unsynced"),
            offlineQueue.deadLetterOperations.count
        ))
    }

    // MARK: - Sign-out

    /// Forgets everything that belongs to the signed-in user (Y1): in-memory
    /// collections and caches, the on-disk cache, the offline queue (unless
    /// `preserveQueue` — a forced sign-out keeps unsynced writes for the
    /// same user's next sign-in; the queue is owner-tagged so nobody else
    /// replays them). Loads still in flight are discarded when they land.
    func resetForSignOut(preserveQueue: Bool = false) {
        sessionEpoch &+= 1
        mutationGeneration &+= 1
        loadRerunRequested = false
        widgetSnapshotTask?.cancel()
        widgetSnapshotTask = nil

        if preserveQueue {
            cache.clearAll(preservingQueue: true)
        } else {
            offlineQueue.reset()
            cache.clearAll()
        }

        allAccounts = []
        transactions = []
        categories = []
        budgets = []
        subscriptions = []
        profile = nil
        profilesMap = [:]
        budgetMembersByBudget = [:]
        externalSpendByBudget = [:]
        externalSpendIncompleteBudgetIds = []
        pendingAutoMatch = nil
        issue = nil
        isLoading = false
        hasLoadedCache = false
        lastCompleteLoadAt = nil
        taggedCacheOwner = nil
        rebuildCaches()
    }

    // MARK: - Refused writes: retry / discard (Y6)

    /// «Повторить»: refused writes go back into the queue, in order, and
    /// replay now (no-op offline — they wait for the network).
    func retryUnsyncedOperations() async {
        offlineQueue.retryDeadLetters()
        if issue?.kind == .unsynced { issue = nil }
        // Every refused op is queued again — its rows are pending again.
        for i in transactions.indices where transactions[i].isUnsynced {
            transactions[i].status = "pending"
        }
        await syncPendingOperations()
    }

    /// «Не сохранять»: forget refused writes. Rows that exist only because
    /// of them (placeholders of refused creates) go now; the rest returns
    /// to the server's version on the next refresh.
    func discardUnsyncedOperations() async {
        let refused = offlineQueue.deadLetterOperations
        offlineQueue.discardDeadLetters()
        if issue?.kind == .unsynced { issue = nil }
        var localOnly: Set<String> = []
        for op in refused {
            if case .create(let input) = op.operation, let id = input.id {
                localOnly.formUnion([id, "\(id)-out", "\(id)-in"])
            }
        }
        if !localOnly.isEmpty {
            noteLocalMutation()
            transactions.removeAll { localOnly.contains($0.id) && $0.isUnsynced }
            persistTransactions()
            rebuildCaches()
            writeWidgetSnapshot()
        }
        await refreshTransactions()
    }

    // MARK: - Widget snapshot & persistence

    /// Persist a fresh `SharedSnapshot` for the widget extension and ask
    /// WidgetKit to reload timelines — debounced: a load plus a save in
    /// quick succession produce one write, not one per step. Safe no-op if
    /// `currencyManager` hasn't been injected yet (tests, cold-start before
    /// wiring).
    private func writeWidgetSnapshot() {
        guard currencyManager != nil else { return }
        widgetSnapshotTask?.cancel()
        widgetSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let currencyManager = self.currencyManager else { return }
            self.widgetSnapshotTask = nil
            SharedSnapshotWriter.write(dataStore: self, currencyManager: currencyManager)
        }
    }

    /// App going to the background: write the pending widget snapshot now
    /// and wait for queued cache writes.
    func flushPendingWrites() {
        if widgetSnapshotTask != nil, let currencyManager {
            widgetSnapshotTask?.cancel()
            widgetSnapshotTask = nil
            SharedSnapshotWriter.write(dataStore: self, currencyManager: currencyManager)
        }
        cache.flushPendingWrites()
    }

    private func persistTransactions() {
        tagCacheOwnerIfNeeded()
        cache.saveTransactions(transactions)
    }

    private func noteLocalMutation() {
        mutationGeneration &+= 1
    }

    // MARK: - Mutations

    func addTransaction(_ input: CreateTransactionInput) async throws -> Transaction {
        // Stamp a client-generated id before anything else: the local
        // placeholder and the server row share identity, so offline
        // edits/deletes of a not-yet-synced row target the right id, and a
        // duplicated replay fails with 23505 which the queue treats as
        // "already synced" (the auto-transfer RPC gets it as `p_id`).
        let stamped = input.withClientId()
        // Y9: a create that returns after a sign-out belongs to the previous
        // user — it must not land in the next user's list, cache or widget.
        let epoch = sessionEpoch

        guard await canReachServer() else {
            guard epoch == sessionEpoch else { throw SessionEndedError() }
            return enqueueCreateLocally(stamped)
        }

        do {
            let tx = try await remote.createTransaction(stamped)
            guard epoch == sessionEpoch else { throw SessionEndedError() }
            noteLocalMutation()
            if !transactions.contains(where: { $0.id == tx.id }) {
                transactions.insert(tx, at: 0)
            }
            persistTransactions()
            rebuildCaches()
            writeWidgetSnapshot()
            AnalyticsService.logAddTransaction(type: stamped.type)
            if epoch == sessionEpoch { await attemptAutoMatch(for: tx) }
            return tx
        } catch {
            if error is SessionEndedError { throw error }
            // Signed out meanwhile: the queue now belongs to nobody (or to
            // the next user) — don't queue the previous user's write there.
            guard epoch == sessionEpoch else { throw SessionEndedError() }
            // The database never answered (lie-fi, the gateway timing out —
            // the 2026-09-10 outage) or answered "try later": queue it like
            // an offline create rather than losing it. The client id makes
            // the replay idempotent even if this attempt did commit.
            guard OfflineQueue.shouldQueueFailedCreate(
                error,
                routesToAutoTransferRPC: stamped.routesToAutoTransferRPC,
                hasClientId: stamped.id != nil
            ) else { throw error }
            AppLogger.data.warning("Create failed without a database answer, queueing offline: \(error)")
            return enqueueCreateLocally(stamped, mayExistOnServer: OfflineQueue.mayHaveCommitted(error))
        }
    }

    /// Queues a create and inserts its full-fidelity local placeholder
    /// (triplet for payment-source expenses) so balances and analytics stay
    /// correct until the queue drains.
    private func enqueueCreateLocally(_ input: CreateTransactionInput, mayExistOnServer: Bool = false) -> Transaction {
        offlineQueue.enqueue(PendingOperation(operation: .create(input), mayExistOnServer: mayExistOnServer))
        noteLocalMutation()
        let nowISO = AppDateFormatters.nowTimestamp()
        let rows = input.routesToAutoTransferRPC
            ? Transaction.placeholderTriplet(for: input, nowISO: nowISO)
            : [Transaction.placeholder(for: input, nowISO: nowISO)]
        transactions.insert(contentsOf: rows, at: 0)
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
        AnalyticsService.logAddTransaction(type: input.type)
        return rows[0]
    }

    /// Drains the queue soon after a mutation was queued while online
    /// (Y4: rows with pending work always go through the queue).
    private func scheduleQueueSync() {
        guard isOnline else { return }
        Task { @MainActor [weak self] in
            await self?.syncPendingOperations()
        }
    }

    // MARK: - Subscription auto-match

    /// Structured event surfaced to the UI when a transaction is automatically
    /// linked to a subscription. Contains enough state to undo the operation.
    struct PendingAutoMatch: Identifiable, Equatable {
        let id = UUID()
        let subscriptionId: String
        let subscriptionName: String
        let paymentId: String
        let previousLastPaymentDate: String?
        let previousNextPaymentDate: String?
    }

    /// If auto-match is enabled in Settings, try to link `tx` to an active
    /// subscription. On success, records a payment via the repository and
    /// surfaces a `PendingAutoMatch` so the UI can offer undo.
    ///
    /// Internal so callers like `BankImportView` (which create rows directly
    /// against `TransactionRepository` rather than via `addTransaction`) can
    /// run the same hook on imported rows. Without this, bank-statement
    /// auto-debits would never land in the subscription's payment history.
    func attemptAutoMatch(for tx: Transaction) async {
        // Setting defaults to ON (key missing → use default of true).
        let autoMatchEnabled: Bool = {
            if UserDefaults.standard.object(forKey: Self.autoMatchEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.autoMatchEnabledKey)
        }()
        guard autoMatchEnabled, tx.type == .expense else { return }

        // Pass FX context so the matcher can score cross-currency candidates —
        // e.g. a RUB-eq charge against a USD subscription. Without this, a
        // legacy tx with `currency = NULL` never clears the amount threshold
        // even when merchant+date already say "this is the Railway charge".
        let ctx = currencyContext
        let fxRatesDouble = ctx.fxRates.mapValues { Double(truncating: $0 as NSDecimalNumber) }
        guard let match = SubscriptionMatcher.bestMatch(
            for: tx,
            in: subscriptions,
            fxRates: fxRatesDouble,
            baseCode: ctx.baseCode,
            accountsById: ctx.accountsById
        ) else { return }

        let sub = match.subscription
        let previousLast = sub.lastPaymentDate
        let previousNext = sub.nextPaymentDate
        let epoch = sessionEpoch

        guard let txDate = SubscriptionDateEngine.parseDbDate(tx.date) else { return }

        do {
            let amountDecimal = Decimal(tx.amountNative) / 100
            let paymentDateStr = SubscriptionDateEngine.formatDbDate(txDate)
            let payment = try await subscriptionRepo.addPayment(
                CreateSubscriptionPaymentInput(
                    subscription_id: sub.id,
                    amount: amountDecimal,
                    currency: sub.currency ?? "RUB",
                    payment_date: paymentDateStr
                )
            )
            // Schedule-anchored next date (a payment two days late keeps the
            // billing day); last_payment_date never moves backwards.
            let newNextDate = SubscriptionDateEngine.nextPaymentDate(for: sub, afterPaymentOn: txDate)
            let newNextStr = SubscriptionDateEngine.formatDbDate(newNextDate)
            let newLastStr = max(previousLast.map { String($0.prefix(10)) } ?? "", paymentDateStr)
            try await subscriptionRepo.updateDates(
                id: sub.id,
                lastPaymentDate: newLastStr,
                nextPaymentDate: newNextStr
            )

            // Signed out while the payment was being recorded (Y9): the
            // server has it; the next user's state, banner and reminders
            // must not.
            guard epoch == sessionEpoch else { return }

            // Local state update.
            if let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                var updated = subscriptions[idx]
                updated.lastPaymentDate = newLastStr
                updated.nextPaymentDate = newNextStr
                noteLocalMutation()
                subscriptions[idx] = updated
                // Reschedule reminder.
                await NotificationManager.scheduleSubscriptionReminder(
                    id: updated.id,
                    serviceName: updated.serviceName,
                    amount: updated.amount,
                    currency: updated.currency ?? "RUB",
                    nextPaymentDate: newNextDate,
                    daysBefore: updated.reminderDays
                )
            }

            guard epoch == sessionEpoch else { return }
            pendingAutoMatch = PendingAutoMatch(
                subscriptionId: sub.id,
                subscriptionName: sub.serviceName,
                paymentId: payment.id,
                previousLastPaymentDate: previousLast,
                previousNextPaymentDate: previousNext
            )
            AnalyticsService.logSubscriptionAutoMatch(score: match.score)
        } catch {
            AppLogger.data.warning("Auto-match payment insert failed: \(error.localizedDescription)")
        }
    }

    /// Walk every loaded expense transaction, score it against the given
    /// subscription, and insert a `subscription_payments` row for every
    /// score that clears `SubscriptionMatcher.matchThreshold` and is not
    /// already recorded.
    ///
    /// This is the "Pull from history" affordance — for users whose
    /// subscriptions existed before the auto-match feature shipped, or
    /// who imported a bank statement that pre-dated the integration.
    /// `SubscriptionMatcher.score` already returns 0 for the date
    /// component when the txn is far from `nextPaymentDate`, so historical
    /// rows fall back to amount + merchant scoring (50 + 20 = 70 ≥ 60),
    /// which is the right behavior here — the date axis is meaningless
    /// for older charges.
    ///
    /// After the pass, the subscription's `last_payment_date` and
    /// `next_payment_date` are advanced to follow the most recent matched
    /// txn so reminders line up with reality.
    ///
    /// Returns the number of newly-inserted payments. 0 means either no
    /// matches or every match was already on file.
    @discardableResult
    func backfillPayments(for subscriptionId: String) async -> Int {
        guard let sub = subscriptions.first(where: { $0.id == subscriptionId }) else { return 0 }

        // Pull existing payments so we can dedupe by (subscription, date).
        // Multiple charges on the same day for the same subscription are
        // rare enough that date-only deduping is the pragmatic default; if
        // it ever bites we'd switch to (date, amount) tuple deduping.
        let existing: [SubscriptionPayment]
        do {
            existing = try await subscriptionRepo.fetchPayments(for: subscriptionId)
        } catch {
            AppLogger.data.warning("Backfill: existing-payments fetch failed: \(error.localizedDescription)")
            return 0
        }
        // Dedupe by the billing CYCLE a payment settles, not by its raw day:
        // the cron charge on the 5th and the bank row on the 7th are one
        // payment.
        var paidCycles = Set(existing.map { SubscriptionDateEngine.cycleKey(forPaymentOn: $0.paymentDate, subscription: sub) })

        // Score every loaded expense txn. We don't pre-filter by currency
        // here — the matcher's amount component already requires a currency
        // match before awarding the 50 points, and merchant alone (20 pts)
        // can't clear the 60-point threshold.
        // Forward FX context so cross-currency historical rows (e.g. RUB-eq
        // tx against a USD sub) still score against the same threshold.
        let ctx = currencyContext
        let fxRatesDouble = ctx.fxRates.mapValues { Double(truncating: $0 as NSDecimalNumber) }
        let candidates: [Transaction] = transactions.filter { $0.type == .expense }
        var matches: [Transaction] = []
        for tx in candidates {
            let scored = SubscriptionMatcher.score(
                transaction: tx,
                subscription: sub,
                fxRates: fxRatesDouble,
                baseCode: ctx.baseCode,
                accountsById: ctx.accountsById
            )
            guard scored.total >= SubscriptionMatcher.matchThreshold else { continue }
            let cycle = SubscriptionDateEngine.cycleKey(forPaymentOn: tx.date, subscription: sub)
            guard !paidCycles.contains(cycle) else { continue }
            paidCycles.insert(cycle)
            matches.append(tx)
        }

        // Insert in chronological order so the last match wins for the
        // updated `last_payment_date`. SubscriptionDateEngine then derives
        // the next-payment date from the rolling cadence — ready for the
        // reminder scheduler.
        matches.sort { $0.date < $1.date }

        var inserted = 0
        var lastMatchDate: String?
        for tx in matches {
            let amountDecimal = Decimal(tx.amountNative) / 100
            let txDayKey = String(tx.date.prefix(10))
            do {
                _ = try await subscriptionRepo.addPayment(
                    CreateSubscriptionPaymentInput(
                        subscription_id: subscriptionId,
                        amount: amountDecimal,
                        currency: sub.currency ?? tx.currency ?? "RUB",
                        payment_date: txDayKey
                    )
                )
                lastMatchDate = txDayKey
                inserted += 1
            } catch {
                AppLogger.data.warning("Backfill payment insert failed: \(error.localizedDescription)")
            }
        }

        // Roll the subscription's payment dates forward to the most recent
        // matched txn. Skip when nothing matched OR when the existing
        // last_payment_date is already at or past our latest match — we
        // don't want to clobber a future-dated reminder with a stale one.
        if let last = lastMatchDate,
           let lastDate = SubscriptionDateEngine.parseDbDate(last) {
            let shouldAdvance: Bool = {
                guard let currentLast = sub.lastPaymentDate,
                      let currentLastDate = SubscriptionDateEngine.parseDbDate(currentLast)
                else { return true }
                return lastDate > currentLastDate
            }()
            if shouldAdvance {
                let nextDate = SubscriptionDateEngine.nextPaymentDate(for: sub, afterPaymentOn: lastDate)
                let nextStr = SubscriptionDateEngine.formatDbDate(nextDate)
                do {
                    try await subscriptionRepo.updateDates(
                        id: subscriptionId,
                        lastPaymentDate: last,
                        nextPaymentDate: nextStr
                    )
                    if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                        var updated = subscriptions[idx]
                        updated.lastPaymentDate = last
                        updated.nextPaymentDate = nextStr
                        noteLocalMutation()
                        subscriptions[idx] = updated
                        await NotificationManager.scheduleSubscriptionReminder(
                            id: updated.id,
                            serviceName: updated.serviceName,
                            amount: updated.amount,
                            currency: updated.currency ?? "RUB",
                            nextPaymentDate: nextDate,
                            daysBefore: updated.reminderDays
                        )
                    }
                } catch {
                    AppLogger.data.warning("Backfill date update failed: \(error.localizedDescription)")
                }
            }
        }

        return inserted
    }

    /// Revert the most recent auto-match: deletes the payment row, restores
    /// the subscription's prior `last_payment_date` / `next_payment_date`, and
    /// reschedules the reminder accordingly.
    func undoAutoMatch() async {
        guard let match = pendingAutoMatch else { return }
        pendingAutoMatch = nil

        do {
            try await subscriptionRepo.deletePayment(id: match.paymentId)
            try await subscriptionRepo.updateDates(
                id: match.subscriptionId,
                lastPaymentDate: match.previousLastPaymentDate,
                nextPaymentDate: match.previousNextPaymentDate
            )
            if let idx = subscriptions.firstIndex(where: { $0.id == match.subscriptionId }) {
                var sub = subscriptions[idx]
                sub.lastPaymentDate = match.previousLastPaymentDate
                sub.nextPaymentDate = match.previousNextPaymentDate
                noteLocalMutation()
                subscriptions[idx] = sub

                if sub.status == .active,
                   let nextStr = sub.nextPaymentDate,
                   let nextDate = SubscriptionDateEngine.parseDbDate(nextStr) {
                    await NotificationManager.scheduleSubscriptionReminder(
                        id: sub.id,
                        serviceName: sub.serviceName,
                        amount: sub.amount,
                        currency: sub.currency ?? "RUB",
                        nextPaymentDate: nextDate,
                        daysBefore: sub.reminderDays
                    )
                } else {
                    await NotificationManager.cancelSubscriptionReminder(id: sub.id)
                }
            }
            AnalyticsService.logSubscriptionAutoMatchUndo()
        } catch {
            reportIssue(.mutation, message: error.localizedDescription)
        }
    }

    /// Clears the pending-match banner (used when the user dismisses or the
    /// timer expires, without undoing).
    /// Clears the pending match — only `id` when given, so an expiring
    /// banner can't dismiss a newer match (V9).
    func clearPendingAutoMatch(id: UUID? = nil) {
        if let id, pendingAutoMatch?.id != id { return }
        pendingAutoMatch = nil
    }

    func updateTransaction(id: String, _ input: UpdateTransactionInput) async throws {
        // A row with queued work (its create, or an earlier offline edit)
        // goes through the queue whatever the connectivity (Y4): a direct
        // UPDATE would match zero rows before the INSERT replays — and
        // "succeed" — or be overwritten later by the older queued edit.
        if offlineQueue.hasPendingOperations(for: id) {
            try applyUpdateOffline(id: id, input)
            scheduleQueueSync()
            return
        }
        guard await canReachServer() else {
            try applyUpdateOffline(id: id, input)
            return
        }

        do {
            try await remote.updateTransaction(id, input)
        } catch {
            // UPDATEs are idempotent (same values on replay), so queueing is
            // safe whenever the database did not answer — dropped connection
            // or gateway 5xx alike — even if the server actually committed.
            guard OfflineQueue.shouldQueueFailedWrite(error) else { throw error }
            AppLogger.data.warning("Update failed without a database answer, queueing offline: \(error)")
            try applyUpdateOffline(id: id, input)
            return
        }

        // Mirror the edit right away, then let the refresh replace it with
        // the server rows.
        noteLocalMutation()
        mirrorUpdateLocally(id: id, input, markPending: false)
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
        await refreshTransactions()
    }

    /// Offline edit: queue the update (coalesces into a queued create when
    /// the row hasn't synced yet) and mirror the change locally.
    private func applyUpdateOffline(id: String, _ input: UpdateTransactionInput) throws {
        guard let tx = transactions.first(where: { $0.id == id }) else {
            throw OfflineMutationError.transactionNotFound
        }
        // The transfer legs of a triplet whose create is still queued are
        // local placeholders — the RPC derives them from the expense. They
        // can't be edited on their own; edit the expense instead (which now
        // coalesces safely, the RPC carries the expense's client id).
        if tx.isAutoTransferLeg,
           let expense = autoTransferExpense(of: tx),
           offlineQueue.hasQueuedCreate(for: expense.id) {
            throw OfflineMutationError.pendingAutoTransferEdit
        }

        offlineQueue.enqueue(PendingOperation(operation: .update(transactionId: id, input)))
        noteLocalMutation()
        mirrorUpdateLocally(id: id, input, markPending: true)
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
    }

    /// Applies an update to the local row (and, for an auto-transfer
    /// expense, to its legs — the local mirror of
    /// `update_expense_with_auto_transfer`).
    private func mirrorUpdateLocally(id: String, _ input: UpdateTransactionInput, markPending: Bool) {
        guard let idx = transactions.firstIndex(where: { $0.id == id }) else { return }
        let tx = transactions[idx]
        var updated = tx.applying(input)
        if !markPending { updated.status = tx.status }
        transactions[idx] = updated
        guard input.useAutoTransferUpdate, let groupId = tx.autoTransferGroupId else { return }
        let legStatuses = Dictionary(
            transactions.filter { $0.autoTransferGroupId == groupId }.map { ($0.id, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        OfflineOverlay.patchAutoTransferLegs(in: &transactions, groupId: groupId, expenseId: id, input: input)
        if !markPending {
            for i in transactions.indices where transactions[i].autoTransferGroupId == groupId && transactions[i].id != id {
                transactions[i].status = legStatuses[transactions[i].id] ?? nil
            }
        }
    }

    /// The expense row an auto-transfer leg belongs to, when visible.
    private func autoTransferExpense(of leg: Transaction) -> Transaction? {
        guard let groupId = leg.autoTransferGroupId else { return nil }
        return transactions.first { $0.autoTransferGroupId == groupId && $0.transferGroupId == nil }
    }

    /// The row a delete must target (Y9). A transfer leg of an auto-transfer
    /// triplet maps to its expense: the server deletes the whole triplet by
    /// expense id, and for a not-yet-synced triplet only the expense id
    /// matches the queued create — the leg's placeholder id (`<id>-out` /
    /// `<id>-in`) matches nothing and isn't even a UUID.
    func deletionTarget(for transaction: Transaction) -> Transaction {
        guard transaction.isAutoTransferLeg, let expense = autoTransferExpense(of: transaction) else {
            return transaction
        }
        return expense
    }

    /// Deletes the row (the whole triplet for an auto-transfer). Throws when
    /// the server rejected it; local state is untouched then. Callers that
    /// chain further writes on success (source reassignment) must use this.
    func deleteTransactionThrowing(_ transaction: Transaction) async throws {
        let target = deletionTarget(for: transaction)
        if let groupId = target.manualTransferGroupId {
            try await deleteTransferGroup(groupId)
            return
        }

        // Queued work on the row → through the queue (Y4); a delete of a
        // queued create cancels it there.
        if offlineQueue.hasPendingOperations(for: target.id) {
            deleteOffline(target)
            scheduleQueueSync()
            return
        }
        guard await canReachServer() else {
            deleteOffline(target)
            return
        }

        do {
            try await remote.deleteTransaction(target.id)
        } catch {
            // A replayed delete of an already-deleted row resolves as synced
            // (PGRST116), so queueing is safe whenever the database did not
            // answer — dropped connection or gateway 5xx alike.
            guard OfflineQueue.shouldQueueFailedWrite(error) else { throw error }
            AppLogger.data.warning("Delete failed without a database answer, queueing offline: \(error)")
            deleteOffline(target)
            return
        }
        noteLocalMutation()
        removeLocal(target)
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
        AnalyticsService.logDeleteTransaction()
    }

    /// Manual transfer (Y8): the list shows one row per `transfer_group_id`,
    /// so deleting "the transfer" means both legs — one request by group,
    /// locally and through the queue. Deleting only the swiped leg left the
    /// other on its account and shifted that balance by the amount.
    private func deleteTransferGroup(_ groupId: String) async throws {
        let legIds = transactions.filter { $0.isManualTransferLeg(ofGroup: groupId) }.map(\.id)
        if legIds.contains(where: offlineQueue.hasPendingOperations(for:)) {
            deleteTransferGroupOffline(groupId, legIds: legIds)
            scheduleQueueSync()
            return
        }
        guard await canReachServer() else {
            deleteTransferGroupOffline(groupId, legIds: legIds)
            return
        }
        do {
            try await remote.deleteTransferGroup(groupId)
        } catch {
            guard OfflineQueue.shouldQueueFailedWrite(error) else { throw error }
            AppLogger.data.warning("Transfer delete failed without a database answer, queueing offline: \(error)")
            deleteTransferGroupOffline(groupId, legIds: legIds)
            return
        }
        noteLocalMutation()
        transactions.removeAll { $0.isManualTransferLeg(ofGroup: groupId) }
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
        AnalyticsService.logDeleteTransaction()
    }

    private func deleteTransferGroupOffline(_ groupId: String, legIds: [String]) {
        offlineQueue.enqueue(PendingOperation(
            operation: .deleteTransferGroup(groupId: groupId, transactionIds: legIds)
        ))
        noteLocalMutation()
        transactions.removeAll { $0.isManualTransferLeg(ofGroup: groupId) }
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
        AnalyticsService.logDeleteTransaction()
    }

    /// Fire-and-forget delete for swipe actions: a failure is shown in the
    /// banner (Y7) instead of vanishing. Returns whether it succeeded.
    @discardableResult
    func deleteTransaction(_ transaction: Transaction) async -> Bool {
        do {
            try await deleteTransactionThrowing(transaction)
            return true
        } catch {
            AppLogger.data.warning("Delete failed: \(error)")
            reportIssue(.mutation, message: String(
                format: String(localized: "sync.error.deleteFailed"),
                error.localizedDescription
            ))
            return false
        }
    }

    /// Offline delete: queue it (coalescing cancels a queued create outright
    /// — nothing reaches the server for rows that never synced) and drop the
    /// row(s) locally, mirroring the online triplet semantics.
    private func deleteOffline(_ transaction: Transaction) {
        offlineQueue.enqueue(PendingOperation(operation: .delete(transactionId: transaction.id)))
        noteLocalMutation()
        removeLocal(transaction)
        persistTransactions()
        rebuildCaches()
        writeWidgetSnapshot()
        AnalyticsService.logDeleteTransaction()
    }

    /// If this row was part of an auto-transfer triplet, the server deletes
    /// ALL three rows (expense + two transfer legs). Remove the sibling rows
    /// from local state too — otherwise the UI would optimistically drop
    /// only the swiped row and the other two would "come back" on the next
    /// recompute/rerender.
    private func removeLocal(_ transaction: Transaction) {
        if let groupId = transaction.autoTransferGroupId {
            transactions.removeAll { $0.autoTransferGroupId == groupId }
        } else {
            transactions.removeAll { $0.id == transaction.id }
        }
    }

    func category(for transaction: Transaction) -> Category? {
        _ = derivedRevision
        guard let categoryId = transaction.categoryId else { return nil }
        return categoryIndex[categoryId]
    }

    /// Categories deduplicated by name+type for UI display (pickers, management).
    /// Prefers the current user's own categories over shared-account duplicates.
    /// Active only: `categories` also holds hidden ones (M11 — budget math and
    /// lookups need them), but nobody picks a hidden category.
    var displayCategories: [Category] {
        let currentUserId = profile?.id ?? ""
        // Sort: current user's categories first so they "win" in dedup
        let sorted = categories.filter(\.isActive).sorted { a, b in
            let aOwn = a.userId == currentUserId
            let bOwn = b.userId == currentUserId
            if aOwn != bOwn { return aOwn }
            return (a.createdAt ?? "") < (b.createdAt ?? "")
        }
        var seen: Set<String> = []
        return sorted.filter { cat in
            let key = "\(cat.name.lowercased().trimmingCharacters(in: .whitespaces))_\(cat.type.rawValue)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    func balance(for account: Account) -> Int64 {
        _ = derivedRevision
        return balanceCache[account.id] ?? account.initialBalance
    }

    /// The account with `id`, of ANY type (debt accounts included) — for
    /// resolving the account of a row or a transfer leg. Never a list.
    func account(withId id: String?) -> Account? {
        guard let id else { return nil }
        return allAccounts.first { $0.id == id }
    }

    /// «Долги» accounts (one per person), open and closed.
    var debtAccounts: [Account] {
        allAccounts.filter(\.isDebtAccount)
    }

    var recentTransactions: [Transaction] {
        Array(transactions.prefix(10))
    }

    // MARK: - Transaction math helpers

    /// Returns `tx.amountNative` FX-normalized to the user's base currency
    /// (kopecks). Use whenever you aggregate transactions across multiple
    /// accounts — `amountNative` is in each account's own currency and
    /// cannot be summed directly.
    ///
    /// Uses the cached FX context (`accountsById`, `fxRatesDecimal`,
    /// `baseCurrencyCode`) — refreshed via `rebuildCurrencyContext()` on
    /// every data/rate/base-currency change. Hot loops that hit this on
    /// every transaction (analytics, cashflow trend) avoid the per-call
    /// dictionary rebuild that previously dominated render time.
    func amountInBase(_ tx: Transaction) -> Int64 {
        TransactionMath.amountInBase(
            tx,
            accountsById: accountsById,
            fxRates: fxRatesDecimal,
            baseCode: baseCurrencyCode
        )
    }

    /// Decimal variant in main units (not kopecks).
    func amountInBaseDisplay(_ tx: Transaction) -> Decimal {
        Decimal(amountInBase(tx)) / 100
    }

    /// Sums transactions, FX-normalizing each into the user's base
    /// currency. Use this helper in place of `reduce { $0 + $1.amount }`
    /// whenever you aggregate multiple transactions — `amountNative`
    /// alone is not comparable across accounts in different currencies,
    /// and `amount` is the legacy field that produced the VND-as-RUB
    /// bug. `signed: true` negates expenses so totals reflect net flow;
    /// `signed: false` (default) sums absolute contributions.
    func aggregate(_ transactions: [Transaction], signed: Bool = false) -> Int64 {
        transactions.reduce(Int64(0)) { acc, tx in
            let base = amountInBase(tx)
            if signed && tx.type == .expense {
                return acc - base
            }
            return acc + base
        }
    }

    /// Bundled FX context — handy when you need to pass it into a pure
    /// engine (InsightEngine, CashFlowEngine, PDFReportGenerator) that
    /// otherwise has no reference to `DataStore`.
    ///
    /// Returns the cached fields directly — the dictionaries are recomputed
    /// once per data/rate change in `rebuildCurrencyContext()`, not on
    /// every call. Callers that hold the tuple over a hot loop pay zero
    /// per-iteration cost.
    ///
    /// Registers a dependency on `derivedRevision` (bumped on every FX
    /// change), so a view that derives numbers from this context re-renders
    /// when rates arrive. `amountInBase(_:)` deliberately doesn't — it runs
    /// thousands of times per render.
    var currencyContext: (accountsById: [String: Account], fxRates: [String: Decimal], baseCode: String) {
        _ = derivedRevision
        return (accountsById, fxRatesDecimal, baseCurrencyCode)
    }

    // MARK: - Assistant Context

    /// Convert internal kopeck value (Int64) to whole currency units (Double).
    private func toUnits(_ kopecks: Int64) -> Double {
        Double(kopecks) / 100.0
    }

    func buildAssistantContext() -> AssistantContext {
        // Build category name lookup for human-readable keys
        let categoryNameById = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Build account name lookup — `uniquingKeysWith` defends against
        // duplicate `account_id` rows from shared-account joins (we own the
        // dedup contract upstream, but a duplicate would otherwise crash
        // `Dictionary(uniqueKeysWithValues:)`).
        // Money accounts only (contract §A7.5): a debt account is a person,
        // and the assistant must never treat «Маша» as an account.
        let accountNameById = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Every figure is labelled with `account.currency`, so it must BE in
        // that currency (M1): `balance(for:)` / `accountIncome` are
        // base-currency caches and the assistant converted them a second time.
        var nativeFlow: [String: (income: Int64, expense: Int64)] = [:]
        for tx in transactions where tx.transferGroupId == nil {
            guard let accountId = tx.accountId else { continue }
            switch tx.type {
            case .income: nativeFlow[accountId, default: (0, 0)].income += tx.amountNative
            case .expense: nativeFlow[accountId, default: (0, 0)].expense += tx.amountNative
            default: break
            }
        }
        let accountSummaries = accounts.map { account in
            AssistantContext.AccountSummary(
                id: account.id,
                name: account.name,
                icon: account.icon,
                balance: toUnits(nativeBalance(for: account)),
                income: toUnits(nativeFlow[account.id]?.income ?? 0),
                expense: toUnits(nativeFlow[account.id]?.expense ?? 0),
                currency: account.currency
            )
        }

        let categorySummaries = categories.map { cat in
            AssistantContext.CategorySummary(
                id: cat.id,
                name: cat.name,
                icon: cat.icon,
                type: cat.type.rawValue
            )
        }

        // Per-category expense totals (use category names as keys for LLM readability)
        var byCategoryKopecks: [String: Int64] = [:]
        // Per-month per-category expense totals for NL queries like "How much on cafes in March?"
        var byMonthCategoryKopecks: [String: [String: Int64]] = [:]
        var totalExpenseKopecks: Int64 = 0
        var totalIncomeKopecks: Int64 = 0

        // ADR-001: balance math uses amount_native (in account currency).
        // To aggregate across multiple accounts with different currencies
        // (e.g. RUB Семейный + USD ByBit) we FX-normalize into base first,
        // otherwise $5 gets summed into rubles as "5 ₽" — off by ~76×.
        //
        // Uses the cached FX context (kept in sync by `rebuildCurrencyContext()`).
        let ctxFx = currencyContext
        let inBase: (Transaction) -> Int64 = { tx in
            TransactionMath.amountInBase(
                tx,
                accountsById: ctxFx.accountsById,
                fxRates: ctxFx.fxRates,
                baseCode: ctxFx.baseCode
            )
        }

        // Transfer legs (manual transfers and the two legs of every
        // auto-transfer triplet) move money between the user's own
        // accounts: counting them double-counts every "Оплачено с" expense
        // and inflates income by the in-leg.
        for tx in transactions where !tx.isTransfer {
            let amount = inBase(tx)
            switch tx.type {
            case .expense:
                totalExpenseKopecks += amount
                if let catId = tx.categoryId {
                    let name = categoryNameById[catId] ?? catId
                    byCategoryKopecks[name, default: 0] += amount
                    let monthKey = String(tx.date.prefix(7))  // yyyy-MM
                    byMonthCategoryKopecks[monthKey, default: [:]][name, default: 0] += amount
                }
            case .income:
                totalIncomeKopecks += amount
            case .transfer:
                break
            }
        }

        // Per-account expense totals (use account names as keys for LLM readability)
        var byAccountKopecks: [String: Int64] = [:]
        for tx in transactions where tx.type == .expense && !tx.isTransfer {
            if let accId = tx.accountId, let name = accountNameById[accId] {
                byAccountKopecks[name, default: 0] += inBase(tx)
            }
        }

        // Convert to whole currency units
        let byCategory = byCategoryKopecks.mapValues { toUnits($0) }
        let byAccount = byAccountKopecks.mapValues { toUnits($0) }
        let byMonthCategory = byMonthCategoryKopecks.mapValues { inner in
            inner.mapValues { toUnits($0) }
        }

        // Date range
        let dates = transactions.map(\.date).sorted()
        let dateFrom = dates.first
        let dateTo = dates.last

        let summary = AssistantContext.TransactionSummary(
            totalExpense: toUnits(totalExpenseKopecks),
            totalIncome: toUnits(totalIncomeKopecks),
            byCategory: byCategory,
            byAccount: byAccount,
            byMonthCategory: byMonthCategory,
            count: transactions.count,
            dateFrom: dateFrom,
            dateTo: dateTo
        )

        // Total balance across all accounts
        let totalBalance = accounts.reduce(0.0) { sum, account in
            sum + toUnits(balance(for: account))
        }

        let currencyCode = (accounts.first?.currency ?? "RUB").uppercased()

        // Resolve the user's effective language preference:
        // `appLanguage` UserDefaults override wins, otherwise system language.
        // This determines which language the AI must respond in.
        let responseLanguage: String = {
            if let override = UserDefaults.standard.string(forKey: "appLanguage"),
               override != "system", !override.isEmpty {
                return override
            }
            return Locale.current.language.languageCode?.identifier ?? "en"
        }()

        // Subscriptions (active only), normalized to monthly rate
        let subSummaries: [AssistantContext.SubscriptionSummary] = subscriptions
            .filter { $0.status == .active }
            .map { sub in
                let monthlyAmount = BudgetMath.normalizedAmount(
                    sub.amount, from: sub.billingPeriod, to: .monthly
                )
                let catName = sub.categoryId.flatMap { categoryNameById[$0] }
                return AssistantContext.SubscriptionSummary(
                    name: sub.serviceName,
                    amountMonthly: toUnits(monthlyAmount),
                    period: sub.billingPeriod.rawValue,
                    nextPaymentDate: sub.nextPaymentDate,
                    category: catName
                )
            }

        // Budgets with computed metrics — FX-normalized via currencyContext
        // so VND/USD transactions sum correctly against the budget's own
        // currency (ADR-001).
        let ctx: BudgetMath.CurrencyContext = ctxFx
        let budgetSummaries: [AssistantContext.BudgetSummary] = budgets
            .filter { $0.isActive }
            .map { budget in
                let metrics = BudgetMath.compute(
                    budget: budget, transactions: transactions, subscriptions: subscriptions,
                    categories: categories,
                    externalSpendRows: externalSpendByBudget[budget.id] ?? [],
                    currencyContext: ctx,
                    members: BudgetMath.memberIds(
                        for: budget, viewerId: profile?.id, budgetMembers: budgetMembersByBudget[budget.id]
                    )
                )
                return AssistantContext.BudgetSummary(
                    name: budget.name,
                    limit: toUnits(metrics.effectiveLimit),
                    spent: toUnits(metrics.spent),
                    remaining: toUnits(metrics.remaining),
                    utilization: metrics.utilization,
                    period: budget.billingPeriod.rawValue,
                    status: metrics.status.rawValue,
                    subscriptionCommitted: toUnits(metrics.subscriptionCommitted)
                )
            }

        return AssistantContext(
            accounts: accountSummaries,
            categories: categorySummaries,
            transactionSummary: summary,
            totalBalance: totalBalance,
            currency: accounts.first?.currency ?? "rub",
            locale: Locale.current.identifier,
            amountUnit: "Amounts are whole units of \(currencyCode) (not minor units). 1500 means 1500 \(currencyCode).",
            subscriptions: subSummaries.isEmpty ? nil : subSummaries,
            budgets: budgetSummaries.isEmpty ? nil : budgetSummaries,
            responseLanguage: responseLanguage,
            fxRates: currencyManager?.rates,
            displayCurrency: currencyManager?.dataCurrency.code.uppercased()
        )
    }


    // MARK: - Cache

    /// Rebuild the FX-context cache (`accountsById`, `fxRatesDecimal`,
    /// `baseCurrencyCode`) from the current `accounts` array and the
    /// injected `currencyManager`. Must be called whenever any of those
    /// inputs change — `rebuildCaches()` does this for us in the data
    /// path; for FX-rate updates that arrive *after* initial load, call
    /// `currencyContextDidChange()` from the rate refresh site.
    ///
    /// Defends against duplicate `account.id` rows (shared-account joins
    /// can return the same account twice) by `uniquingKeysWith` instead of
    /// the crash-on-duplicate `Dictionary(uniqueKeysWithValues:)`.
    private func rebuildCurrencyContext() {
        baseCurrencyCode = currencyManager?.dataCurrency.code.uppercased() ?? "RUB"
        fxRatesDecimal = (currencyManager?.rates ?? [:]).mapValues { Decimal($0) }
        // Every account — a debt leg converts by its own account's currency.
        accountsById = Dictionary(
            allAccounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Public hook for `CurrencyManager` / `AppViewModel` to trigger a
    /// refresh of the cached FX context after rates or the base currency
    /// change. Also re-runs `rebuildCaches()` because per-account balances
    /// are stored in base currency and become stale when the FX table
    /// changes.
    func currencyContextDidChange() {
        rebuildCaches()
        // FX feeds every base-currency figure, including ones derived from
        // `currencyContext` outside the caches — always invalidate.
        derivedRevision &+= 1
        writeWidgetSnapshot()
    }

    /// Rebuild all caches in one pass — call after any data change.
    ///
    /// Skip-equal: each rebuilt cache is compared with the current one and
    /// only a real change bumps `derivedRevision` (one observable write for
    /// all of them); `categories` is reassigned only when the dedup actually
    /// removed a row. A rebuild that changes nothing invalidates no view.
    ///
    /// ADR-001 + legacy-UI contract: balance_cache and per-account sums are
    /// kept in **base currency** (kopecks) because `AccountCarouselView` and
    /// friends assume `formatAmount(balance)` takes a base-currency number
    /// and FX-converts into the display currency. Math itself is done in the
    /// account's own currency (via `tx.amountNative`) and then normalized to
    /// base just before caching. Without the FX step a USD account's
    /// balance got interpreted as RUB and divided by the rate again, which
    /// is why ByBit showed "$8.42" instead of "$640".
    func rebuildCaches() {
        // Refresh the FX-context cache first so downstream getters
        // (`amountInBase`, `currencyContext`) see the same snapshot of
        // `accounts` / `currencyManager.rates` we use here.
        rebuildCurrencyContext()
        let baseCode = baseCurrencyCode
        let fxRates = fxRatesDecimal
        let accountCurrencyById: [String: String] = Dictionary(
            allAccounts.map { ($0.id, $0.currency.uppercased()) },
            uniquingKeysWith: { first, _ in first }
        )

        var incomeByAccount: [String: Int64] = [:]
        var expenseByAccount: [String: Int64] = [:]

        // Monthly aggregate buckets — populated in the same pass so we don't
        // walk `transactions` twice. Excludes transfers (see contract on
        // `MonthlyAggregate`).
        var monthlyGlobal: [String: (income: Int64, expense: Int64)] = [:]
        var monthlyByAccount: [String: [String: (income: Int64, expense: Int64)]] = [:]

        for tx in transactions {
            guard let accountId = tx.accountId else { continue }
            let accountCcy = accountCurrencyById[accountId] ?? baseCode
            // ADR-001: amount_native is canonical, always in account currency.
            // Normalize into base before caching so the legacy UI contract
            // (balance stored in base kopecks, FX-converted at render time)
            // keeps working.
            let amountInBase = NetWorthCalculator.convert(
                amount: tx.amountNative,
                from: accountCcy,
                to: baseCode,
                rates: fxRates
            )
            switch tx.type {
            case .income:
                incomeByAccount[accountId, default: 0] += amountInBase
            case .expense:
                expenseByAccount[accountId, default: 0] += amountInBase
            case .transfer:
                // Legacy transfer type — treat positive as income, negative as expense
                if amountInBase > 0 {
                    incomeByAccount[accountId, default: 0] += amountInBase
                } else {
                    expenseByAccount[accountId, default: 0] += abs(amountInBase)
                }
            }

            // Monthly buckets — net cashflow only. Skip both the dedicated
            // transfer type and any row that's a leg of a multi-row transfer
            // (`transferGroupId != nil`).
            guard tx.type != .transfer, tx.transferGroupId == nil else { continue }
            let monthKey = String(tx.date.prefix(7))  // yyyy-MM (UTC-consistent with tx.date)
            switch tx.type {
            case .income:
                monthlyGlobal[monthKey, default: (0, 0)].income += amountInBase
                monthlyByAccount[accountId, default: [:]][monthKey, default: (0, 0)].income += amountInBase
            case .expense:
                monthlyGlobal[monthKey, default: (0, 0)].expense += amountInBase
                monthlyByAccount[accountId, default: [:]][monthKey, default: (0, 0)].expense += amountInBase
            case .transfer:
                break  // unreachable — guarded above
            }
        }

        // Debt accounts get a balance too (the «Долги» screen reads it);
        // they are simply never summed into a total.
        var newBalances: [String: Int64] = [:]
        for account in allAccounts {
            let initialInBase = NetWorthCalculator.convert(
                amount: account.initialBalance,
                from: account.currency.uppercased(),
                to: baseCode,
                rates: fxRates
            )
            let income = incomeByAccount[account.id] ?? 0
            let expense = expenseByAccount[account.id] ?? 0
            newBalances[account.id] = initialInBase + income - expense
        }

        // Deduplicate categories by ID only (shared accounts may return same row twice).
        // We must NOT deduplicate by name because different users may have categories
        // with the same name but different IDs, and transactions reference those IDs.
        var seenIds: Set<String> = []
        let dedupedCategories = categories.filter { seenIds.insert($0.id).inserted }
        if dedupedCategories.count != categories.count {
            categories = dedupedCategories
        }
        let newCategoryIndex = Dictionary(uniqueKeysWithValues: dedupedCategories.map { ($0.id, $0) })

        var derivedChanged = false
        if balanceCache != newBalances {
            balanceCache = newBalances
            derivedChanged = true
        }
        if accountIncomeStorage != incomeByAccount {
            accountIncomeStorage = incomeByAccount
            derivedChanged = true
        }
        if accountExpenseStorage != expenseByAccount {
            accountExpenseStorage = expenseByAccount
            derivedChanged = true
        }
        if categoryIndex != newCategoryIndex {
            categoryIndex = newCategoryIndex
            derivedChanged = true
        }
        if derivedChanged {
            derivedRevision &+= 1
        }

        // Materialize the monthly aggregate dictionaries from the (income, expense)
        // tuple buckets we accumulated above.
        monthlyAggregates = monthlyGlobal.reduce(into: [String: MonthlyAggregate]()) { acc, kv in
            acc[kv.key] = MonthlyAggregate(monthKey: kv.key, income: kv.value.income, expense: kv.value.expense)
        }
        monthlyAggregatesByAccount = monthlyByAccount.reduce(into: [String: [String: MonthlyAggregate]]()) { outer, kv in
            outer[kv.key] = kv.value.reduce(into: [String: MonthlyAggregate]()) { inner, mv in
                inner[mv.key] = MonthlyAggregate(monthKey: mv.key, income: mv.value.income, expense: mv.value.expense)
            }
        }

        // Bump generation token last — readers that see a new token are
        // guaranteed to see the new aggregate dictionaries too.
        txGenerationToken &+= 1
    }
}

extension DataStore {
    /// Returns the last `months` monthly aggregates, sorted chronologically
    /// (oldest first). When `accountId` is supplied, the values are scoped
    /// to that account; otherwise the global aggregates are used.
    ///
    /// Months without any non-transfer activity are filled with a zero
    /// `MonthlyAggregate` so chart x-axes don't gap. The window is anchored
    /// to the current calendar month (in UTC, matching `tx.date`'s yyyy-MM).
    func recentMonthlyAggregates(months: Int = 6, accountId: String? = nil) -> [MonthlyAggregate] {
        guard months > 0 else { return [] }

        let source: [String: MonthlyAggregate]
        if let accountId {
            source = monthlyAggregatesByAccount[accountId] ?? [:]
        } else {
            source = monthlyAggregates
        }

        // Build the month-key window ending at "now" in the LOCAL calendar:
        // the stored keys are `prefix(7)` of the local wall-clock date, so a
        // UTC window dropped the current month's bar from 00:00 to 07:00 on
        // the 1st for UTC+7 users.
        let calendar = AppDateFormatters.localCalendar
        let now = Date()
        let formatter = AppDateFormatters.localMonth

        var keys: [String] = []
        keys.reserveCapacity(months)
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            keys.append(formatter.string(from: date))
        }

        return keys.map { key in
            source[key] ?? MonthlyAggregate(monthKey: key, income: 0, expense: 0)
        }
    }
}
