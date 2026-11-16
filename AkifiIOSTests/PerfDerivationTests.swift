import XCTest
import Observation
@testable import AkifiIOS

/// The perf fixes replace per-render scans with memoized derivations.
/// Every memo here is checked two ways: (1) the derived value equals what the
/// old per-render code computed, on randomized data, and (2) it is computed
/// once per key and recomputed when — and only when — an input changes.
@MainActor
final class PerfDerivationTests: XCTestCase {

    // MARK: - Fixture

    /// Deterministic SplitMix64 so failures reproduce.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let me = "user-me"
    private static let partner = "user-partner"

    private static let utcDay: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let utcStamp: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return df
    }()

    private func tx(
        _ id: String,
        user: String = me,
        account: String? = "acc-rub",
        amount: Int64 = 100_00,
        type: TransactionType = .expense,
        at date: Date,
        category: String? = "cat-1",
        transferGroup: String? = nil,
        currencyLabel: String? = nil,
        source: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: user, accountId: account, amount: amount, amountNative: amount,
            currency: currencyLabel, description: nil, categoryId: category, type: type,
            date: Self.utcDay.string(from: date), rawDateTime: Self.utcStamp.string(from: date),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: transferGroup,
            paymentSourceAccountId: source, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func makeStore(_ transactions: [Transaction] = []) -> (DataStore, CurrencyManager) {
        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = ["USD": 1, "RUB": 100, "THB": 35]
        store.currencyManager = cm
        store.accounts = [
            Account(id: "acc-rub", userId: Self.me, name: "RUB", icon: "💳", color: "#000000", initialBalance: 0, currency: "rub"),
            Account(id: "acc-usd", userId: Self.me, name: "USD", icon: "💵", color: "#000000", initialBalance: 0, currency: "usd"),
            Account(id: "acc-thb", userId: Self.me, name: "THB", icon: "🇹🇭", color: "#000000", initialBalance: 0, currency: "thb"),
        ]
        store.categories = (0..<6).map {
            AkifiIOS.Category(id: "cat-\($0)", userId: Self.me, accountId: nil, name: "C\($0)", icon: "🛒",
                              color: "#22C55E", type: $0 < 4 ? .expense : .income, isActive: true, createdAt: nil)
        }
        store.transactions = transactions
        store.rebuildCaches()
        return (store, cm)
    }

    private func randomTransactions(_ count: Int, seed: UInt64, spanDays: Double = 400) -> [Transaction] {
        var rng = SeededRNG(state: seed)
        let now = Date()
        let accounts = ["acc-rub", "acc-usd", "acc-thb", nil]
        var out: [Transaction] = []
        for i in 0..<count {
            let when = now.addingTimeInterval(-Double.random(in: -3 * 86_400...(spanDays * 86_400), using: &rng))
            let roll = Int.random(in: 0..<10, using: &rng)
            let type: TransactionType = roll < 6 ? .expense : (roll < 9 ? .income : .transfer)
            let group: String? = Int.random(in: 0..<8, using: &rng) == 0 ? "g-\(i / 2)" : nil
            out.append(tx(
                "t-\(i)",
                user: Bool.random(using: &rng) ? Self.me : Self.partner,
                account: accounts[Int.random(in: 0..<accounts.count, using: &rng)],
                amount: Int64.random(in: 1_00...50_000_00, using: &rng),
                type: type,
                at: when,
                category: Int.random(in: 0..<7, using: &rng) == 0 ? nil : "cat-\(Int.random(in: 0..<6, using: &rng))",
                transferGroup: group
            ))
        }
        return out.sorted { $0.rawDateTime > $1.rawDateTime }
    }

    // MARK: - ArrayIdentity / Memo

    func test_arrayIdentity_tracksStorageNotContent() {
        var a = [1, 2, 3]
        let id = ArrayIdentity(a)
        XCTAssertEqual(id, ArrayIdentity(a), "same storage")
        let copy = a
        XCTAssertEqual(ArrayIdentity(copy), id, "a copy shares storage until mutated")
        a[0] = 1   // same value, but a write — must copy away from the memo's storage
        XCTAssertNotEqual(ArrayIdentity(a), id, "any write while the memo holds the old storage is a change")
        XCTAssertNotEqual(ArrayIdentity([1, 2, 3]), id, "an equal but freshly built array is not assumed equal")
        XCTAssertEqual(ArrayIdentity([Int]()), ArrayIdentity([Int]()), "empty arrays are interchangeable")
    }

    func test_memo_computesOncePerKey_andKeepsCapacity() {
        let memo = Memo<Int, String>(capacity: 2)
        XCTAssertEqual(memo.value(for: 1) { "one" }, "one")
        XCTAssertEqual(memo.value(for: 1) { "WRONG" }, "one")
        XCTAssertEqual(memo.value(for: 2) { "two" }, "two")
        XCTAssertEqual(memo.value(for: 1) { "WRONG" }, "one", "capacity 2 keeps both sides of a toggle")
        XCTAssertEqual(memo.value(for: 3) { "three" }, "three")   // evicts 2 (least recently used)
        XCTAssertEqual(memo.value(for: 2) { "two again" }, "two again")
        XCTAssertEqual(memo.computeCount, 4)
    }

    // MARK: - DayKey

    /// The string threshold must agree with the old per-row parse
    /// (`yyyy-MM-dd` → local midnight ≥ start) in every time zone.
    func test_dayKeyThreshold_matchesParsedMidnightComparison() {
        var rng = SeededRNG(state: 7)
        for tzId in ["Asia/Novosibirsk", "Europe/Moscow", "America/New_York", "UTC", "Pacific/Kiritimati"] {
            let tz = TimeZone(identifier: tzId)!
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = tz
            parser.dateFormat = "yyyy-MM-dd"
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            for i in 0..<300 {
                var start = Date().addingTimeInterval(-Double.random(in: 0...(400 * 86_400), using: &rng))
                if i % 10 == 0 { start = cal.startOfDay(for: start) }   // exact-midnight starts too
                let threshold = DayKey.Threshold(since: start, timeZone: tz)
                for delta in -2...2 {
                    let day = parser.string(from: start.addingTimeInterval(Double(delta) * 86_400))
                    let old = parser.date(from: day).map { $0 >= start } ?? false
                    XCTAssertEqual(threshold.admits(day), old, "\(tzId) start=\(start) day=\(day)")
                }
            }
        }
        XCTAssertFalse(DayKey.Threshold(since: Date()).admits("garbage"))
    }

    func test_dayKey_isGregorianRegardlessOfDeviceCalendar() {
        let date = Self.utcStamp.date(from: "2026-11-17T05:00:00+00:00")!
        XCTAssertEqual(DayKey.day(date, timeZone: TimeZone(identifier: "UTC")!), "2026-11-17")
        XCTAssertEqual(DayKey.month(date, timeZone: TimeZone(identifier: "Asia/Novosibirsk")!), "2026-11")
        XCTAssertEqual(DayKey.recentMonths(3, now: date, timeZone: TimeZone(identifier: "UTC")!),
                       ["2026-09", "2026-10", "2026-11"])
    }

    // MARK: - TransactionInstant (D11)

    func test_transactionInstant_parsesPostgrestShapes() {
        let base = Self.utcStamp.date(from: "2026-11-16T14:38:22+00:00")!
        XCTAssertEqual(TransactionInstant.parse("2026-11-16T14:38:22+00:00"), base)
        XCTAssertEqual(TransactionInstant.parse("2026-11-16T14:38:22Z"), base)
        XCTAssertEqual(TransactionInstant.parse("2026-11-16 14:38:22+00"), base)
        XCTAssertEqual(TransactionInstant.parse("2026-11-16T21:38:22+07:00"), base)
        XCTAssertEqual(TransactionInstant.parse("2026-11-16T09:38:22-0500"), base)
        XCTAssertEqual(TransactionInstant.parse("2026-11-16T14:38:22"), base, "no offset = UTC, as the server stores it")
        XCTAssertEqual(TransactionInstant.parse("2026-11-16T14:38:22.311938+00:00")!.timeIntervalSince(base), 0.311938, accuracy: 1e-6)
        XCTAssertEqual(TransactionInstant.parse("2026-11-16"), Self.utcDay.date(from: "2026-11-16"))
        XCTAssertNil(TransactionInstant.parse("garbage"))
        XCTAssertNil(TransactionInstant.parse("2026-11-16T14:38:22+7"))
    }

    func test_settledBadge_comparesInstants_notMidnight() {
        // Settlement recorded at 03:51 UTC. An expense booked that evening is
        // NOT covered (it used to be: its day's midnight is before 03:51).
        let watermark = TransactionInstant.parse("2026-10-07T03:51:39.311938+00:00")
        let morning = tx("m", at: Self.utcStamp.date(from: "2026-10-07T01:00:00+00:00")!)
        let evening = tx("e", at: Self.utcStamp.date(from: "2026-10-07T18:00:00+00:00")!)
        let dayBefore = tx("b", at: Self.utcStamp.date(from: "2026-10-06T23:59:00+00:00")!)
        XCTAssertTrue(SharedAccountDetailView.isCoveredBySettlement(morning, watermark: watermark))
        XCTAssertTrue(SharedAccountDetailView.isCoveredBySettlement(dayBefore, watermark: watermark))
        XCTAssertFalse(SharedAccountDetailView.isCoveredBySettlement(evening, watermark: watermark))
        XCTAssertFalse(SharedAccountDetailView.isCoveredBySettlement(morning, watermark: nil))
    }

    func test_settlementRows_matchOldFilter() {
        var txs = randomTransactions(800, seed: 11)
        txs = txs.map { t in
            var t = t
            if Int(t.id.dropFirst(2))! % 3 == 0 { t.paymentSourceAccountId = "acc-usd" }
            return t
        }
        let interval = SettlementPeriod.quarter.dateInterval()
        let old = Array(txs.filter { t in
            guard t.accountId == "acc-rub", t.type == .expense, t.transferGroupId == nil,
                  let s = t.paymentSourceAccountId, s != "acc-rub",
                  let d = Self.utcDay.date(from: t.date) else { return false }
            return interval.contains(d)
        }.prefix(100))
        let new = SharedAccountDetailView.settlementRows(txs, accountId: "acc-rub", interval: interval)
        XCTAssertEqual(new.map(\.id), old.map(\.id))
        XCTAssertFalse(new.isEmpty)
    }

    // MARK: - TransactionIndex / recent rows (P6, P4)

    func test_transactionIndex_matchesPerRowScans() {
        let txs = randomTransactions(600, seed: 3)
        let index = TransactionIndex.build(transactions: txs, viewerId: Self.me)
        for t in txs {
            let oldPair = t.transferGroupId.flatMap { g in txs.first { $0.transferGroupId == g && $0.id != t.id } }
            XCTAssertEqual(index.transferPartner(of: t)?.id, oldPair?.id)
            XCTAssertEqual(index.transferPartner(of: t)?.accountId, oldPair?.accountId)
            if let acc = t.accountId {
                let oldShared = txs.contains { $0.accountId == acc && $0.userId != Self.me }
                XCTAssertEqual(index.accountsWithOtherAuthors.contains(acc), oldShared)
            }
        }
    }

    func test_recentTransactions_matchOldFilterAndAreMemoized() {
        let txs = randomTransactions(500, seed: 5)
        let (store, _) = makeStore(txs)
        for accountId in [nil, "acc-rub", "acc-thb"] as [String?] {
            let base = accountId.map { id in txs.filter { $0.accountId == id } } ?? txs
            var seen: Set<String> = []
            let old = Array(base.filter { t in
                if let g = t.transferGroupId {
                    if seen.contains(g) { return false }
                    seen.insert(g)
                }
                return true
            }.prefix(10))
            XCTAssertEqual(store.derivedCache.recentTransactions(for: store, accountId: accountId).map(\.id), old.map(\.id))
        }
        let cache = store.derivedCache
        let before = cache.indexComputeCount
        _ = cache.transactionIndex(for: store)
        _ = cache.transactionIndex(for: store)
        XCTAssertEqual(cache.indexComputeCount, before + 1, "index built once per data revision")
        store.transactions.insert(tx("new", user: Self.partner, account: "acc-usd", at: Date()), at: 0)
        store.rebuildCaches()
        XCTAssertTrue(cache.transactionIndex(for: store).accountsWithOtherAuthors.contains("acc-usd"))
        XCTAssertEqual(cache.indexComputeCount, before + 2)
    }

    func test_derivedCache_isPerStore() {
        let (a, _) = makeStore([tx("a", at: Date())])
        let (b, _) = makeStore([tx("b", at: Date())])
        XCTAssertFalse(a.derivedCache === b.derivedCache)
        XCTAssertTrue(a.derivedCache === a.derivedCache)
        XCTAssertEqual(b.derivedCache.recentTransactions(for: b, accountId: nil).map(\.id), ["b"])
    }

    // MARK: - Membership (B7)

    private func member(_ account: String, _ user: String, weight: Decimal = 1) -> AccountMember {
        AccountMember(id: "\(account)-\(user)", accountId: account, userId: user,
                      role: user == Self.me ? .owner : .editor, splitWeight: weight)
    }

    func test_membership_sharedComesFromMemberRows_notFromPartnerTransactions() async {
        let store = AccountMembershipStore()
        XCTAssertNil(store.isShared("acc-rub", viewerId: Self.me), "unknown before the first load")

        // Freshly shared account: partner joined, booked nothing yet.
        let rows = [member("acc-rub", Self.me), member("acc-rub", Self.partner), member("acc-usd", Self.me)]
        store.fetchMembers = { rows }
        await store.refresh(viewerId: Self.me)
        XCTAssertEqual(store.isShared("acc-rub", viewerId: Self.me), true)
        XCTAssertEqual(store.isShared("acc-usd", viewerId: Self.me), false)
        XCTAssertNil(store.isShared("acc-new", viewerId: Self.me), "account unseen by the snapshot = unknown")
        XCTAssertNil(store.isShared("acc-rub", viewerId: "someone-else"), "a snapshot never answers for another user")
        XCTAssertEqual(store.sharedAccountIds(viewerId: Self.me), ["acc-rub"])
    }

    func test_membership_failedRefreshKeepsSnapshot_andFreshSnapshotSkipsNetwork() async {
        let store = AccountMembershipStore()
        store.apply([member("acc-rub", Self.me), member("acc-rub", Self.partner)], for: Self.me)

        struct Offline: Error {}
        store.fetchMembers = { throw Offline() }
        await store.refresh(viewerId: Self.me, force: true)
        XCTAssertEqual(store.isShared("acc-rub", viewerId: Self.me), true, "offline must not flip a shared account to personal")

        let calls = Counter()
        store.fetchMembers = { await calls.bump(); return [] }
        await store.refresh(viewerId: Self.me, maxAge: 60)
        let afterFresh = await calls.value
        XCTAssertEqual(afterFresh, 0, "a snapshot younger than maxAge is reused")
    }

    func test_membership_concurrentRefreshesShareOneRequest() async {
        let store = AccountMembershipStore()
        let calls = Counter()
        let rows = [member("acc-rub", Self.me)]
        store.fetchMembers = {
            await calls.bump()
            try await Task.sleep(for: .milliseconds(50))
            return rows
        }
        async let first: Void = store.refresh(viewerId: Self.me)
        async let second: Void = store.refresh(viewerId: Self.me)
        _ = await (first, second)
        let n = await calls.value
        XCTAssertEqual(n, 1)
    }

    func test_membership_equalSnapshotDoesNotNotifyObservers() {
        let store = AccountMembershipStore()
        let rows = [member("acc-rub", Self.me), member("acc-rub", Self.partner)]
        store.apply(rows, for: Self.me)
        let flag = Flag()
        withObservationTracking {
            _ = store.membersByAccount
        } onChange: {
            flag.fired = true
        }
        store.apply(rows, for: Self.me)
        XCTAssertFalse(flag.fired, "re-applying equal rows must not re-render Home and every row")
        store.apply([member("acc-rub", Self.me), member("acc-rub", Self.partner, weight: 2)], for: Self.me)
        XCTAssertTrue(flag.fired, "a changed split weight is a change")
    }

    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - Analytics (P1)

    func test_analyticsState_derivesOncePerKey_andInvalidatesOnRealChanges() {
        let (store, cm) = makeStore(randomTransactions(400, seed: 9))
        let state = AnalyticsTabState(dataStore: store)

        for _ in 0..<10 {
            _ = state.categoryBreakdown(type: .expense)
            _ = state.cashflowPoints
            _ = state.forecast(horizonMonths: 3)
            _ = state.monthlyAggregates()
        }
        XCTAssertEqual(state.computeCounts["breakdown"], 1)
        XCTAssertEqual(state.computeCounts["cashflow"], 1)
        XCTAssertEqual(state.computeCounts["forecast"], 1)
        XCTAssertEqual(state.computeCounts["aggregates"], 1)
        XCTAssertEqual(state.computeCounts["period"], 1, "both panels share one period filter")

        // New transaction → everything recomputes once.
        let before = state.categoryBreakdown(type: .expense).total
        store.transactions.insert(tx("fresh", amount: 1_000_00, at: Date()), at: 0)
        store.rebuildCaches()
        XCTAssertEqual(state.categoryBreakdown(type: .expense).total, before + 1_000)
        XCTAssertEqual(state.computeCounts["breakdown"], 2)

        // FX change (rates refresh → currencyContextDidChange) → amounts change.
        let usdShare = state.categoryBreakdown(type: .expense).total
        cm.rates["RUB"] = 50
        store.currencyContextDidChange()
        XCTAssertNotEqual(state.categoryBreakdown(type: .expense).total, usdShare)
        XCTAssertEqual(state.computeCounts["breakdown"], 3)

        // Filters are part of the key.
        state.selectedAccountId = "acc-usd"
        _ = state.categoryBreakdown(type: .expense)
        XCTAssertEqual(state.computeCounts["breakdown"], 4)
        state.selectedPeriod = .year
        _ = state.categoryBreakdown(type: .expense)
        XCTAssertEqual(state.computeCounts["breakdown"], 5)
    }

    /// Same totals as the old in-view `computeData()`.
    func test_categoryBreakdown_matchesOldComputation() {
        let txs = randomTransactions(700, seed: 21)
        let (store, _) = makeStore(txs)
        let state = AnalyticsTabState(dataStore: store)
        for period in WidgetPeriod.allCases {
            state.selectedPeriod = period
            for type in [CategoryType.expense, .income] {
                let start = period.startDate()
                let oldFilter = DateFormatter()
                oldFilter.dateFormat = "yyyy-MM-dd"
                oldFilter.locale = Locale(identifier: "en_US_POSIX")
                let filtered = txs.filter { t in oldFilter.date(from: t.date).map { $0 >= start } ?? false }
                var oldTotals: [String: Decimal] = [:]
                for t in filtered where !t.isTransfer && t.type == (type == .expense ? .expense : .income) {
                    oldTotals[t.categoryId ?? "uncategorized", default: 0] += store.amountInBaseDisplay(t)
                }
                let result = state.categoryBreakdown(type: type)
                XCTAssertEqual(result.filtered.map(\.id), filtered.map(\.id), "\(period)")
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.spending.map { ($0.id, $0.amount) }),
                               oldTotals.filter { _ in oldTotals.values.reduce(0, +) > 0 }, "\(period) \(type)")
                XCTAssertEqual(result.spending.map(\.amount), result.spending.map(\.amount).sorted(by: >))
            }
        }
    }

    /// The period picker now drives the cashflow bucketing (it was stuck on
    /// weekly buckets because nothing updated `AnalyticsViewModel.selectedPeriod`).
    func test_cashflowBuckets_followThePeriodPicker() {
        let now = Date()
        let txs = (0..<5).map { tx("d\($0)", at: now.addingTimeInterval(-Double($0) * 86_400 - 60)) }
            + [tx("old", at: now.addingTimeInterval(-200 * 86_400))]
        let (store, _) = makeStore(txs)
        let state = AnalyticsTabState(dataStore: store)

        state.selectedPeriod = .week
        XCTAssertEqual(state.cashflowPoints.count, Set(state.periodTransactions.map(\.date)).count, "daily bars")

        state.selectedPeriod = .year
        let monthKeys = Set(state.periodTransactions.map { String($0.date.prefix(7)) })
        XCTAssertEqual(state.cashflowPoints.count, monthKeys.count, "monthly bars")

        XCTAssertEqual(AnalyticsPeriod(WidgetPeriod.day), .week)
        XCTAssertEqual(AnalyticsPeriod(WidgetPeriod.month), .month)
        XCTAssertEqual(AnalyticsPeriod(WidgetPeriod.threeMonths), .quarter)
        XCTAssertEqual(AnalyticsPeriod(WidgetPeriod.year), .year)
    }

    func test_demoMode_feedsDemoDataThroughTheSameDerivations() {
        let (store, _) = makeStore([])
        let state = AnalyticsTabState(dataStore: store)
        XCTAssertTrue(state.isDemo)
        XCTAssertEqual(state.scopedTransactions.map(\.id), DemoData.transactions.map(\.id))
        XCTAssertTrue(state.monthlyAggregates().isEmpty)
    }

    // MARK: - Mini dashboard / Home summary

    func test_miniDashboardMonths_matchOldComputation() {
        let txs = randomTransactions(900, seed: 33, spanDays: 250)
        let (store, _) = makeStore(txs)
        let cal = Calendar.current
        let now = Date()
        let months: [String] = (0..<6).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
            let c = cal.dateComponents([.year, .month], from: d)
            return "\(c.year!)-\(String(format: "%02d", c.month!))"
        }
        let new = TransactionsMiniDashboardView.months(txs, now: now) { store.amountInBase($0) }
        XCTAssertEqual(new.map(\.id), months)
        for (entry, key) in zip(new, months) {
            let rows = txs.filter { !$0.isTransfer && $0.date.hasPrefix(key) }
            let inc = rows.filter { $0.type == .income }.reduce(Int64(0)) { $0 + store.amountInBase($1) }
            let exp = rows.filter { $0.type == .expense }.reduce(Int64(0)) { $0 + store.amountInBase($1) }
            XCTAssertEqual(entry.income, Double(inc) / 100, key)
            XCTAssertEqual(entry.expense, Double(exp) / 100, key)
        }
        XCTAssertEqual(new.filter(\.isCurrent).map(\.id), [months.last!])
    }

    func test_summaryMonthTotals_matchOldComputation() {
        let txs = randomTransactions(900, seed: 44, spanDays: 70)
        let (store, _) = makeStore(txs)
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        for accountId in [nil, "acc-usd"] as [String?] {
            let month = txs.filter { t in
                if let accountId, t.accountId != accountId { return false }
                return parser.date(from: t.date).map { $0 >= monthStart } ?? false
            }
            let inc = month.filter { $0.type == .income && !$0.isTransfer }.reduce(Int64(0)) { $0 + store.amountInBase($1) }
            let exp = month.filter { $0.type == .expense && !$0.isTransfer }.reduce(Int64(0)) { $0 + store.amountInBase($1) }
            let new = SummaryCardsView.monthTotals(txs, accountId: accountId, monthStart: DayKey.month(Date()) + "-01") {
                store.amountInBase($0)
            }
            XCTAssertEqual(new.income, inc)
            XCTAssertEqual(new.expense, exp)
        }
    }

    // MARK: - Transaction row amount (M8)

    func test_rowAmount_usesAccountCurrency_notLegacyLabel() {
        // 5 000 ₽ on a RUB account carrying a stale "USD" label.
        let mislabeled = tx("m", account: "acc-rub", amount: 5_000_00, at: Date(), currencyLabel: "USD")
        let thb = tx("t", account: "acc-thb", amount: 350_00, at: Date(), currencyLabel: "RUB")
        let (store, cm) = makeStore([mislabeled, thb])

        XCTAssertEqual(TransactionRowView.displayValue(of: mislabeled, dataStore: store, currencyManager: cm), 5_000,
                       "shown as 5 000 ₽, not as $5 000 converted")
        // 350 THB at 35 THB/USD, 100 RUB/USD = 1 000 ₽ — the same number the
        // detail screen and the balance use.
        XCTAssertEqual(TransactionRowView.displayValue(of: thb, dataStore: store, currencyManager: cm), 1_000)
        XCTAssertEqual(TransactionRowView.displayValue(of: thb, dataStore: store, currencyManager: cm),
                       cm.convert(abs(store.amountInBaseDisplay(thb))))

        // User-typed foreign amount keeps priority.
        var foreign = tx("f", account: "acc-rub", amount: 1_000_00, at: Date())
        foreign.foreignAmount = 10
        foreign.foreignCurrency = "USD"
        XCTAssertEqual(TransactionRowView.displayValue(of: foreign, dataStore: store, currencyManager: cm), 1_000)
    }

    func test_formatInCurrency_cachedFormatterKeepsOutput() {
        let cm = CurrencyManager()
        let first = cm.formatInCurrency(1_234.5, currency: .usd)
        XCTAssertEqual(cm.formatInCurrency(1_234.5, currency: .usd), first)
        XCTAssertNotEqual(cm.formatInCurrency(1_234.5, currency: .usd, wholeUnits: true), first)
        XCTAssertTrue(first.hasSuffix(Currency.usd.symbol))
    }
}
