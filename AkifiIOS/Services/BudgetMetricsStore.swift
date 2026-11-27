import Foundation
import Observation

/// A budget's numbers as every budget screen should show them.
struct ResolvedBudgetMetrics {
    enum Source: Equatable {
        /// Exactly what `get_budget_metrics` returned for the current data.
        case server
        /// The last server answer, moved by THIS phone's changes since then
        /// (an expense added offline, a pull-to-refresh still running). The
        /// partner part stays at its last known value.
        case serverAdjusted
        /// No usable server answer: `BudgetMath` over local data.
        case local
    }

    let budget: Budget
    let metrics: BudgetMetrics
    let source: Source
    /// The last server call failed (or the phone is offline) and this is a
    /// shared budget: a partner's newest spending may be missing (B5). The
    /// card says so instead of silently showing a smaller number.
    let isPartial: Bool
    /// The server's payload, when one is in use (members, category names).
    let server: ServerBudgetMetrics?
    /// Spent today in the budget currency (minor units) — the widget's
    /// «потрачено сегодня» with the card's own matching rules (B8).
    let spentToday: Int64
}

/// Last successful `get_budget_metrics` answer plus what this phone's own
/// data summed to at that moment. Persisted, so a cold start offline still
/// shows the last good shared numbers (B5).
struct BudgetMetricsSnapshot: Codable, Sendable, Equatable {
    struct Baseline: Codable, Sendable, Equatable {
        /// Fingerprint of the budget definition the server computed with —
        /// an edited budget falls back to local math until the next fetch.
        let definition: String
        /// This phone's own visible spend for the server window (server
        /// rates, no partner rows) at fetch time.
        let ownSpent: Int64
        /// Same for the server's "today".
        let ownSpentToday: Int64
    }

    let userId: String
    /// The local day the server computed for ("yyyy-MM-dd").
    let day: String
    let fetchedAt: Date
    /// `DataStore.txGenerationToken` the answer corresponds to. Meaningless
    /// across launches; a restored snapshot is always treated as stale.
    var generation: UInt64
    let budgets: [String: ServerBudgetMetrics]
    let baselines: [String: Baseline]
    /// `BudgetMetricsStore.inputsFingerprint` at fetch time (Y2): partner
    /// spend, subscriptions and members are server inputs too — the answer
    /// is exact only while they are unchanged. nil in payloads persisted
    /// before this field (stale anyway after a relaunch).
    var inputs: Int? = nil
}

/// Pure resolution: which numbers each budget shows. No I/O, unit-tested.
enum BudgetMetricsResolver {

    struct Input {
        var budgets: [Budget]
        var transactions: [Transaction]
        var subscriptions: [SubscriptionTracker]
        var categories: [Category]
        var externalSpendByBudget: [String: [BudgetMath.ExternalSpendRow]]
        var memberCountByBudget: [String: Int]
        var currencyContext: BudgetMath.CurrencyContext
        var generation: UInt64
        var now: Date
        /// `BudgetMetricsStore.inputsFingerprint` of the current data; nil
        /// = not tracked (callers that only compare generations).
        var inputs: Int? = nil
    }

    struct Mismatch: Equatable {
        /// "spent" or "period".
        let field: String
        let diff: Int64
    }

    static func resolve(
        _ input: Input,
        snapshot: BudgetMetricsSnapshot?,
        lastFetchFailed: Bool
    ) -> [String: ResolvedBudgetMetrics] {
        let today = dayKey(input.now)
        var out: [String: ResolvedBudgetMetrics] = [:]
        out.reserveCapacity(input.budgets.count)
        for budget in input.budgets {
            let shared = (input.memberCountByBudget[budget.id] ?? 1) > 1
            let partial = shared && lastFetchFailed
            if let snapshot, let server = snapshot.budgets[budget.id],
               let resolved = fromServer(budget: budget, server: server, snapshot: snapshot,
                                         input: input, today: today, partial: partial) {
                out[budget.id] = resolved
                continue
            }
            let external = input.externalSpendByBudget[budget.id] ?? []
            let metrics = BudgetMath.compute(
                budget: budget,
                transactions: input.transactions,
                subscriptions: input.subscriptions,
                categories: input.categories,
                externalSpendRows: external,
                currencyContext: input.currencyContext,
                now: input.now
            )
            let spentToday = BudgetMath.spentOnDay(
                input.now, budget: budget, transactions: input.transactions,
                categories: input.categories, externalSpendRows: external,
                currencyContext: input.currencyContext
            )
            out[budget.id] = ResolvedBudgetMetrics(
                budget: budget, metrics: metrics, source: .local,
                isPartial: partial, server: nil, spentToday: spentToday
            )
        }
        return out
    }

    private static func fromServer(
        budget: Budget,
        server s: ServerBudgetMetrics,
        snapshot: BudgetMetricsSnapshot,
        input: Input,
        today: String,
        partial: Bool
    ) -> ResolvedBudgetMetrics? {
        guard let period = s.period,
              let baseline = snapshot.baselines[budget.id],
              baseline.definition == definitionKey(budget) else { return nil }

        if snapshot.generation == input.generation && snapshot.day == today
            && (input.inputs == nil || snapshot.inputs == input.inputs) {
            return ResolvedBudgetMetrics(
                budget: budget, metrics: BudgetMath.metrics(fromServer: s), source: .server,
                isPartial: false, server: s, spentToday: s.spentToday
            )
        }

        // Stale answer: usable while today is still inside its window.
        let todayStart = BudgetMath.calendar.startOfDay(for: input.now)
        guard period.start <= todayStart, todayStart <= period.end else { return nil }

        let ctx = serverRatesContext(input.currencyContext, server: s)
        let ownNow = BudgetMath.spentAmount(
            budget: budget, transactions: input.transactions, period: period,
            categories: input.categories, currencyContext: ctx
        )
        let spent = max(0, s.spent + (ownNow - baseline.ownSpent))
        let metrics = BudgetMath.assemble(
            limit: s.limit, carryIn: s.carryIn, spent: spent,
            subscriptionCommitted: s.subscriptionCommitted, period: period, today: input.now
        )

        let spentToday: Int64
        if snapshot.day == today {
            let ownTodayNow = BudgetMath.spentAmount(
                budget: budget, transactions: input.transactions,
                period: (todayStart, todayStart), categories: input.categories, currencyContext: ctx
            )
            spentToday = max(0, s.spentToday + (ownTodayNow - baseline.ownSpentToday))
        } else {
            spentToday = BudgetMath.spentOnDay(
                input.now, budget: budget, transactions: input.transactions,
                categories: input.categories,
                externalSpendRows: input.externalSpendByBudget[budget.id] ?? [],
                currencyContext: ctx
            )
        }
        return ResolvedBudgetMetrics(
            budget: budget, metrics: metrics, source: .serverAdjusted,
            isPartial: partial, server: s, spentToday: spentToday
        )
    }

    /// This phone's own visible spend for the server's window/today, with the
    /// server's rates — stored with each snapshot as the baseline.
    static func baseline(for budget: Budget, server s: ServerBudgetMetrics, input: Input) -> BudgetMetricsSnapshot.Baseline? {
        guard let period = s.period else { return nil }
        let ctx = serverRatesContext(input.currencyContext, server: s)
        let own = BudgetMath.spentAmount(
            budget: budget, transactions: input.transactions, period: period,
            categories: input.categories, currencyContext: ctx
        )
        let todayStart = BudgetMath.calendar.startOfDay(for: input.now)
        let ownToday = BudgetMath.spentAmount(
            budget: budget, transactions: input.transactions, period: (todayStart, todayStart),
            categories: input.categories, currencyContext: ctx
        )
        return .init(definition: definitionKey(budget), ownSpent: own, ownSpentToday: ownToday)
    }

    /// Server vs the phone's own computation on the SAME window and rates.
    /// A disagreement means the phone's view of the data differs from the
    /// server's (the class of bug that showed different numbers to two
    /// members). Up to one kopeck per counted row is rounding noise.
    static func mismatches(for budget: Budget, server s: ServerBudgetMetrics, input: Input) -> [Mismatch] {
        guard let period = s.period else { return [] }
        var out: [Mismatch] = []
        let local = BudgetMath.currentPeriod(for: budget, now: input.now)
        let df = AppDateFormatters.isoDate
        if df.string(from: local.start) != s.periodStart || df.string(from: local.end) != s.periodEnd {
            let days = BudgetMath.calendar.dateComponents([.day], from: local.start, to: period.start).day ?? 0
            out.append(Mismatch(field: "period", diff: Int64(days)))
        }
        let ctx = serverRatesContext(input.currencyContext, server: s)
        let localSpent = BudgetMath.spentAmount(
            budget: budget, transactions: input.transactions, period: period,
            categories: input.categories, currencyContext: ctx
        ) + BudgetMath.externalSpent(
            rows: input.externalSpendByBudget[budget.id] ?? [], budget: budget,
            period: period, currencyContext: ctx
        )
        let diff = abs(localSpent - s.spent)
        if diff > Int64(max(1, s.txCount)) {
            out.append(Mismatch(field: "spent", diff: diff))
        }
        return out
    }

    /// Client rates with the server's on top, and the budget currency the
    /// server used — so the same rows convert to the same kopecks.
    static func serverRatesContext(
        _ ctx: BudgetMath.CurrencyContext,
        server s: ServerBudgetMetrics
    ) -> BudgetMath.CurrencyContext {
        guard !s.fx.isEmpty else { return ctx }
        var rates = ctx.fxRates
        for (code, value) in s.fx where value > 0 {
            rates[code.uppercased()] = Decimal(value)
        }
        return (ctx.accountsById, rates, ctx.baseCode)
    }

    static func definitionKey(_ b: Budget) -> String {
        [
            String(b.amount),
            b.billingPeriod.rawValue,
            (b.categoryIds ?? []).sorted().joined(separator: ","),
            (b.accountIds ?? []).sorted().joined(separator: ","),
            b.currency?.uppercased() ?? "",
            b.rolloverEnabled ? "r" : "",
            b.customStartDate ?? "",
            b.customEndDate ?? "",
        ].joined(separator: "|")
    }

    static func dayKey(_ date: Date) -> String {
        AppDateFormatters.isoDate.string(from: date)
    }
}

/// One shared, memoized source of budget numbers for every screen that shows
/// them — the Budgets tab, its health summary, «Доступно сегодня» and the
/// widget snapshot (P5: one cache instead of four recomputations).
///
/// Server first (B1): `get_budget_metrics` sees every member's rows, so a
/// shared budget shows the same numbers on both phones and in pushes. The
/// local `BudgetMath` result is the offline fallback and a cross-check that
/// logs `budget_integrity_mismatch` when the two disagree — same pattern as
/// `SettlementViewModel` / `get_account_settlement`.
@MainActor
@Observable
final class BudgetMetricsStore {
    static let shared = BudgetMetricsStore()

    private(set) var snapshot: BudgetMetricsSnapshot?
    private(set) var lastFetchFailed = false
    private(set) var isRefreshing = false

    @ObservationIgnored private var memo: (key: MemoKey, value: [String: ResolvedBudgetMetrics])?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var lastAttempt: (key: FetchKey, at: Date, ok: Bool)?
    @ObservationIgnored private weak var dataStore: DataStore?
    @ObservationIgnored private var reportedMismatches: Set<String> = []
    @ObservationIgnored private let persistenceURL: URL?

    /// Network seam — tests inject a stub.
    @ObservationIgnored var fetcher: @Sendable (_ today: String, _ timeZone: String) async throws -> ServerBudgetMetricsResponse = { today, tz in
        try await BudgetRepository().fetchMetrics(today: today, timeZone: tz)
    }
    /// Off under XCTest so DataStore tests that write widget snapshots never
    /// reach the network.
    @ObservationIgnored var autoRefreshEnabled = !BudgetMetricsStore.isRunningUnitTests
    /// Whether the SDK holds a session — without one the RPC would go out
    /// as anon. Seam for tests.
    @ObservationIgnored var sessionPresent: @MainActor () -> Bool = {
        SupabaseManager.shared.client.auth.currentSession != nil
    }
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    nonisolated static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(persistenceURL: URL? = BudgetMetricsStore.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        if let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
           var restored = try? JSONDecoder().decode(BudgetMetricsSnapshot.self, from: data) {
            restored.generation = .max  // never "fresh" after a relaunch
            snapshot = restored
        }
    }

    nonisolated static var defaultPersistenceURL: URL? {
        guard !isRunningUnitTests else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("budget-metrics.json")
    }

    // MARK: - Reading

    /// Metrics for every budget in `dataStore.budgets`, memoized on the data
    /// generation, the server snapshot and the day. Safe to call from `body`
    /// (only @ObservationIgnored state is written).
    func resolved(for dataStore: DataStore, now: Date = Date()) -> [String: ResolvedBudgetMetrics] {
        // Read the observed inputs so callers re-render when they change.
        let budgets = dataStore.budgets
        let transactions = dataStore.transactions
        let subscriptions = dataStore.subscriptions
        let categories = dataStore.categories
        let external = dataStore.externalSpendByBudget
        let members = dataStore.budgetMembersByBudget
        let userId = dataStore.profile?.id
        let usableSnapshot = snapshot.flatMap { $0.userId == userId ? $0 : nil }
        let failed = lastFetchFailed
        let inputs = Self.inputsFingerprint(subscriptions: subscriptions, external: external, members: members)

        let key = MemoKey(
            generation: dataStore.txGenerationToken,
            txCount: transactions.count,
            budgets: Self.hash(budgets.map(BudgetMetricsResolver.definitionKey) + budgets.map(\.id)),
            categories: Self.hash(categories.map { "\($0.id)|\($0.name)" }),
            inputs: inputs,
            snapshotStamp: usableSnapshot?.fetchedAt,
            snapshotGeneration: usableSnapshot?.generation,
            lastFetchFailed: failed,
            day: BudgetMetricsResolver.dayKey(now)
        )
        if let memo, memo.key == key { return memo.value }

        let input = BudgetMetricsResolver.Input(
            budgets: budgets,
            transactions: transactions,
            subscriptions: subscriptions,
            categories: categories,
            externalSpendByBudget: external,
            memberCountByBudget: members.mapValues(\.count),
            currencyContext: dataStore.currencyContext,
            generation: dataStore.txGenerationToken,
            now: now,
            inputs: inputs
        )
        let value = BudgetMetricsResolver.resolve(input, snapshot: usableSnapshot, lastFetchFailed: failed)
        memo = (key, value)
        return value
    }

    // MARK: - Fetching

    /// Fetches server metrics when the data, the budgets or the day changed
    /// since the last successful fetch. Cheap to call often: concurrent calls
    /// coalesce into one follow-up fetch; a failure backs off for 30 s.
    /// Called from `SharedSnapshotWriter.write` (i.e. after every DataStore
    /// load or mutation) and from the screens on appear.
    func refreshIfNeeded(dataStore: DataStore, force: Bool = false) {
        guard autoRefreshEnabled else { return }
        self.dataStore = dataStore
        // No session → every PostgREST call would go out as anon (Y2).
        guard sessionPresent(), dataStore.profile?.id != nil,
              !dataStore.budgets.isEmpty,
              let key = Self.fetchKey(for: dataStore, now: now()) else { return }
        if inFlight != nil {
            rerunRequested = true
            return
        }
        if !force, let last = lastAttempt, last.key == key,
           last.ok || Date().timeIntervalSince(last.at) < 30 {
            return
        }
        guard dataStore.isConnectedProvider() else {
            // Offline: whatever we show may miss a partner's newest spend.
            if !lastFetchFailed { lastFetchFailed = true }
            lastAttempt = (key, Date(), false)
            return
        }
        let fetcher = self.fetcher
        inFlight = Task { [weak self] in
            await self?.performFetch(key: key, fetcher: fetcher)
        }
    }

    /// Awaitable variant for `.task` / pull-to-refresh. `force` (an explicit
    /// pull) always asks the server again — after a fetch already in flight,
    /// which may have started before the data the user is looking at.
    func refresh(dataStore: DataStore, force: Bool = false) async {
        if force {
            while let running = inFlight { await running.value }
        }
        refreshIfNeeded(dataStore: dataStore, force: force)
        await inFlight?.value
    }

    /// Forget everything (sign-out). Removes the persisted snapshot too.
    func reset() {
        inFlight?.cancel()
        inFlight = nil
        rerunRequested = false
        lastAttempt = nil
        memo = nil
        snapshot = nil
        lastFetchFailed = false
        reportedMismatches = []
        if let persistenceURL { try? FileManager.default.removeItem(at: persistenceURL) }
    }

    /// Applies a server answer (also the test entry point). `inputs` is the
    /// fingerprint the request was made for (default: the current data).
    func apply(
        _ response: ServerBudgetMetricsResponse,
        generation: UInt64,
        dataStore: DataStore,
        now: Date = Date(),
        inputs: Int? = nil
    ) {
        guard let userId = dataStore.profile?.id else { return }
        let input = BudgetMetricsResolver.Input(
            budgets: dataStore.budgets,
            transactions: dataStore.transactions,
            subscriptions: dataStore.subscriptions,
            categories: dataStore.categories,
            externalSpendByBudget: dataStore.externalSpendByBudget,
            memberCountByBudget: dataStore.budgetMembersByBudget.mapValues(\.count),
            currencyContext: dataStore.currencyContext,
            generation: generation,
            now: now
        )
        let budgetsById = Dictionary(dataStore.budgets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let serverById = Dictionary(response.budgets.map { ($0.budgetId, $0) }, uniquingKeysWith: { a, _ in a })
        var baselines: [String: BudgetMetricsSnapshot.Baseline] = [:]
        for (id, server) in serverById {
            guard let budget = budgetsById[id],
                  let baseline = BudgetMetricsResolver.baseline(for: budget, server: server, input: input) else { continue }
            baselines[id] = baseline
        }
        let snap = BudgetMetricsSnapshot(
            userId: userId, day: response.today, fetchedAt: now, generation: generation,
            budgets: serverById, baselines: baselines,
            inputs: inputs ?? Self.inputsFingerprint(
                subscriptions: dataStore.subscriptions,
                external: dataStore.externalSpendByBudget,
                members: dataStore.budgetMembersByBudget
            )
        )
        snapshot = snap
        lastFetchFailed = false

        // Cross-check only when the phone's data is exactly what the server
        // saw: nothing queued offline, nothing changed while in flight.
        if dataStore.txGenerationToken == generation && !dataStore.offlineQueue.hasPending {
            reportMismatches(serverById: serverById, budgetsById: budgetsById, input: input, day: response.today)
        }
        persist(snap)
    }

    private func performFetch(
        key: FetchKey,
        fetcher: @Sendable (String, String) async throws -> ServerBudgetMetricsResponse
    ) async {
        isRefreshing = true
        var applied = false
        do {
            let response = try await fetcher(key.day, TimeZone.current.identifier)
            if let ds = dataStore, ds.profile?.id == key.userId {
                apply(response, generation: key.generation, dataStore: ds, inputs: key.inputs)
                lastAttempt = (key, Date(), true)
                applied = true
            }
        } catch {
            lastFetchFailed = true
            lastAttempt = (key, Date(), false)
            AppLogger.data.error("get_budget_metrics failed, using local fallback: \(error.localizedDescription)")
        }
        isRefreshing = false
        inFlight = nil

        // The widget snapshot picks up the server numbers. Its own
        // refreshIfNeeded call is a no-op for an unchanged key.
        if applied, let ds = dataStore, let cm = ds.currencyManager {
            SharedSnapshotWriter.write(dataStore: ds, currencyManager: cm)
        }
        if rerunRequested {
            rerunRequested = false
            if let ds = dataStore { refreshIfNeeded(dataStore: ds) }
        }
    }

    private func reportMismatches(
        serverById: [String: ServerBudgetMetrics],
        budgetsById: [String: Budget],
        input: BudgetMetricsResolver.Input,
        day: String
    ) {
        for (id, server) in serverById {
            guard let budget = budgetsById[id] else { continue }
            for mismatch in BudgetMetricsResolver.mismatches(for: budget, server: server, input: input) {
                // Once per budget, field and day — telemetry, not a stream.
                let dedupe = "\(id)|\(mismatch.field)|\(day)"
                guard reportedMismatches.insert(dedupe).inserted else { continue }
                let shared = (input.memberCountByBudget[id] ?? 1) > 1
                AppLogger.data.error(
                    "budget mismatch: \(mismatch.field, privacy: .public) differs by \(mismatch.diff) (shared: \(shared, privacy: .public))"
                )
                AnalyticsService.logEvent("budget_integrity_mismatch", params: [
                    "field": mismatch.field,
                    "diff": mismatch.diff,
                    "shared": shared,
                    "period_type": budget.billingPeriod.rawValue,
                ])
            }
        }
    }

    private func persist(_ snap: BudgetMetricsSnapshot) {
        guard let persistenceURL, let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: persistenceURL, options: [.atomic])
    }

    // MARK: - Keys

    private struct MemoKey: Equatable {
        let generation: UInt64
        let txCount: Int
        let budgets: Int
        let categories: Int
        let inputs: Int
        let snapshotStamp: Date?
        let snapshotGeneration: UInt64?
        let lastFetchFailed: Bool
        let day: String
    }

    /// What a server answer was computed from. A change of any part means
    /// the numbers on screen may be stale and the server is asked again.
    struct FetchKey: Equatable {
        let userId: String
        let generation: UInt64
        let day: String
        let budgets: Int
        /// Partner spend, subscriptions, members — see `inputsFingerprint`.
        let inputs: Int
    }

    static func fetchKey(for dataStore: DataStore, now: Date = Date()) -> FetchKey? {
        guard let userId = dataStore.profile?.id else { return nil }
        return FetchKey(
            userId: userId,
            generation: dataStore.txGenerationToken,
            day: BudgetMetricsResolver.dayKey(now),
            budgets: hash(dataStore.budgets.map(BudgetMetricsResolver.definitionKey) + dataStore.budgets.map(\.id)),
            inputs: inputsFingerprint(
                subscriptions: dataStore.subscriptions,
                external: dataStore.externalSpendByBudget,
                members: dataStore.budgetMembersByBudget
            )
        )
    }

    /// Content hash of the server inputs that don't move
    /// `txGenerationToken` (Y2): a partner's spending only changes
    /// `externalSpendByBudget`, a subscription edit only `subscriptions`, a
    /// new member only `budgetMembersByBudget`. Every field that feeds the
    /// numbers is hashed — a partner's 500 ₽ becoming 1 500 ₽ keeps the row
    /// count, so counts can't be the key.
    static func inputsFingerprint(
        subscriptions: [SubscriptionTracker],
        external: [String: [BudgetMath.ExternalSpendRow]],
        members: [String: [BudgetMember]]
    ) -> Int {
        var h = Hasher()
        h.combine(subscriptions.count)
        for s in subscriptions.sorted(by: { $0.id < $1.id }) {
            h.combine(s.id); h.combine(s.amount); h.combine(s.currency)
            h.combine(s.billingPeriod.rawValue); h.combine(s.status.rawValue); h.combine(s.isActive)
            h.combine(s.startDate); h.combine(s.lastPaymentDate); h.combine(s.nextPaymentDate)
            h.combine(s.categoryId); h.combine(s.accountId)
        }
        h.combine(external.count)
        for budgetId in external.keys.sorted() {
            h.combine(budgetId)
            for row in external[budgetId] ?? [] {
                h.combine(row.txId); h.combine(row.amountNative); h.combine(row.currency); h.combine(row.txDate)
            }
        }
        h.combine(members.count)
        for budgetId in members.keys.sorted() {
            h.combine(budgetId)
            for m in (members[budgetId] ?? []).sorted(by: { $0.id < $1.id }) {
                h.combine(m.id); h.combine(m.userId); h.combine(m.role.rawValue)
            }
        }
        return h.finalize()
    }

    private static func hash(_ parts: [String]) -> Int {
        var h = Hasher()
        for p in parts { h.combine(p) }
        return h.finalize()
    }
}
