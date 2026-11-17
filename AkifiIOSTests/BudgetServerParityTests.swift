import XCTest
@testable import AkifiIOS

/// `get_budget_metrics` (migration 20261117130003) vs `BudgetMath` on the
/// same inputs.
///
/// `serverJSON` is the RPC's real output for the synthetic shared budget in
/// the migration's dry-run fixture (run against prod inside BEGIN…ROLLBACK
/// on 2026-11-17, p_today = 2026-11-17):
///   - weekly budget «ZZ Кафе», 1 000 ₽, rollover on, owner V, member O;
///   - V: $10 on his USD card today, category «ZZ Кафе Тест» (his);
///   - O: 100 000 ₫ yesterday and 250 000 ₫ last week on her VND card, her
///     own same-name category « zz кафе тест » (different id);
///   - O: active $5/month subscription in that category (+ a paused one);
///   - rates per USD: RUB 82.5688, VND 25715.743135.
/// If the SQL or the Swift math changes, one of these tests must change too.
final class BudgetServerParityTests: XCTestCase {

    static let serverJSON = """
    {"version":1,"today":"2026-11-17","generated_at":"2026-11-17T08:00:00+00:00","budgets":[
    {"fx":{"RUB":82.5688,"USD":1,"VND":25715.743135},"name":"ZZ Кафе","limit":100000,"spent":114677,"carry_in":19729,
     "currency":"RUB","tx_count":2,"budget_id":"00000000-0000-4000-8000-0000000000b1",
     "by_member":[{"spent":82569,"user_id":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","tx_count":1},
                  {"spent":32108,"user_id":"66673fe4-69ee-429f-b0a2-81b9e838b41d","tx_count":1}],
     "remaining":5052,"categories":[{"id":"00000000-0000-4000-8000-0000000000c1","icon":"☕","name":"ZZ Кафе Тест"}],
     "fx_missing":[],"member_ids":["2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","66673fe4-69ee-429f-b0a2-81b9e838b41d"],
     "pace_ratio":3.35,"period_end":"2026-11-22","total_days":7,"period_type":"weekly","spent_today":82569,
     "utilization":95,"elapsed_days":2,"period_start":"2026-11-16","free_remaining":0,"remaining_days":6,
     "effective_limit":119729,"alert_thresholds":[80,100],"subscription_count":1,"safe_to_spend_daily":0,
     "subscription_committed":9495}]}
    """

    // MARK: - Fixture

    static let vladimir = "2ebaaa87-1e23-46f7-a66e-c85d2bb8227c"
    static let olga = "66673fe4-69ee-429f-b0a2-81b9e838b41d"
    static let budgetId = "00000000-0000-4000-8000-0000000000b1"
    static let catV = "00000000-0000-4000-8000-0000000000c1"
    static let catO = "00000000-0000-4000-8000-0000000000c2"
    static let catOther = "00000000-0000-4000-8000-0000000000c3"
    static let usdCard = "00000000-0000-4000-8000-0000000000a1"
    static let vndCard = "00000000-0000-4000-8000-0000000000a2"

    /// 2026-11-17 12:00 in the device zone — the same calendar day as the
    /// server's p_today whatever zone the simulator runs in.
    static var now: Date {
        BudgetMath.calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
    }

    static var budget: Budget {
        Budget(
            id: budgetId, userId: vladimir, budgetName: "ZZ Кафе",
            amount: 1_000_00, billingPeriod: .weekly, categoryIds: [catV],
            rolloverEnabled: true, alertThresholds: [80, 100], currency: "RUB",
            createdAt: "2026-11-01T10:00:00.000000+00:00"
        )
    }

    static var context: BudgetMath.CurrencyContext {
        let accounts = [
            Account(id: usdCard, userId: vladimir, name: "ZZ USD card", icon: "💳", color: "blue", initialBalance: 0, currency: "usd"),
            Account(id: vndCard, userId: olga, name: "ZZ VND card", icon: "💳", color: "blue", initialBalance: 0, currency: "vnd"),
        ]
        let rates: [String: Decimal] = [
            "USD": 1,
            "RUB": Decimal(string: "82.5688")!,
            "VND": Decimal(string: "25715.743135")!,
        ]
        return (Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) }), rates, "RUB")
    }

    static func category(_ id: String, _ userId: String, _ name: String) -> AkifiIOS.Category {
        AkifiIOS.Category(id: id, userId: userId, accountId: nil, name: name, icon: "☕",
                          color: "#4ADE80", type: .expense, isActive: true, createdAt: nil)
    }

    static func tx(_ id: String, user: String, account: String, category: String, amount: Int64,
                   type: TransactionType = .expense, date: String, transferGroupId: String? = nil) -> Transaction {
        Transaction(
            id: id, userId: user, accountId: account,
            amount: amount, amountNative: amount, currency: nil,
            description: nil, categoryId: category, type: type,
            date: date, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: transferGroupId, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    /// Every row in the fixture — what the server sees.
    static var allTransactions: [Transaction] {
        [
            tx("t101", user: vladimir, account: usdCard, category: catV, amount: 10_00, date: "2026-11-17"),
            tx("t102", user: olga, account: vndCard, category: catO, amount: 100_000_00, date: "2026-11-16"),
            tx("t103", user: olga, account: vndCard, category: catO, amount: 250_000_00, date: "2026-11-10"),
            tx("t104", user: olga, account: vndCard, category: catOther, amount: 777_000_00, date: "2026-11-16"),
            tx("t105", user: olga, account: vndCard, category: catO, amount: 999_000_00, type: .income, date: "2026-11-16"),
            tx("t106", user: olga, account: vndCard, category: catO, amount: 555_000_00, date: "2026-11-16", transferGroupId: "g1"),
        ]
    }

    static var allCategories: [AkifiIOS.Category] {
        [category(catV, vladimir, "ZZ Кафе Тест"), category(catO, olga, " zz кафе тест "), category(catOther, olga, "ZZ Другое")]
    }

    static var allSubscriptions: [SubscriptionTracker] {
        [
            SubscriptionTracker(id: "s1", userId: olga, serviceName: "ZZ Sub", amount: 5_00, currency: "USD",
                                billingPeriod: .monthly, startDate: "2026-01-01", lastPaymentDate: nil,
                                nextPaymentDate: nil, categoryId: catO, reminderDays: 1, iconColor: nil,
                                isActive: true, status: .active),
            SubscriptionTracker(id: "s2", userId: olga, serviceName: "ZZ Paused", amount: 9_00, currency: "USD",
                                billingPeriod: .monthly, startDate: "2026-01-01", lastPaymentDate: nil,
                                nextPaymentDate: nil, categoryId: catO, reminderDays: 1, iconColor: nil,
                                isActive: false, status: .paused),
        ]
    }

    static func decodeServer() throws -> ServerBudgetMetricsResponse {
        try JSONDecoder().decode(ServerBudgetMetricsResponse.self, from: Data(serverJSON.utf8))
    }

    // MARK: - Parity: identical inputs → identical numbers

    func test_localMathOnServersInputs_matchesServerExactly() throws {
        let server = try XCTUnwrap(Self.decodeServer().budgets.first)
        let local = BudgetMath.compute(
            budget: Self.budget,
            transactions: Self.allTransactions,
            subscriptions: Self.allSubscriptions,
            categories: Self.allCategories,
            currencyContext: Self.context,
            now: Self.now
        )
        let df = AppDateFormatters.isoDate
        XCTAssertEqual(df.string(from: local.periodStart), server.periodStart)
        XCTAssertEqual(df.string(from: local.periodEnd), server.periodEnd)
        XCTAssertEqual(local.spent, server.spent, "spent")
        XCTAssertEqual(local.carryIn, server.carryIn, "rollover carry (M10)")
        XCTAssertEqual(local.effectiveLimit, server.effectiveLimit)
        XCTAssertEqual(local.subscriptionCommitted, server.subscriptionCommitted, "subscriptions (B3)")
        XCTAssertEqual(local.remaining, server.remaining)
        XCTAssertEqual(local.freeRemaining, server.freeRemaining)
        XCTAssertEqual(local.safeToSpendDaily, server.safeToSpendDaily)
        XCTAssertEqual(local.utilization, server.utilization)
        XCTAssertEqual(local.paceRatio, server.paceRatio, accuracy: 0.0001)
        XCTAssertEqual(local.totalDays, server.totalDays)
        XCTAssertEqual(local.elapsedDays, server.elapsedDays)
        XCTAssertEqual(local.remainingDays, server.remainingDays)

        let spentToday = BudgetMath.spentOnDay(
            Self.now, budget: Self.budget, transactions: Self.allTransactions,
            categories: Self.allCategories, currencyContext: Self.context
        )
        XCTAssertEqual(spentToday, server.spentToday)

        // The server-mapped metrics are what the card shows.
        let mapped = BudgetMath.metrics(fromServer: server)
        XCTAssertEqual(mapped.spent, local.spent)
        XCTAssertEqual(mapped.status, local.status)
        XCTAssertEqual(mapped.riskLevel, local.riskLevel)
        XCTAssertEqual(mapped.progressColor, local.progressColor)
        XCTAssertEqual(mapped.periodStart, local.periodStart)
    }

    // MARK: - B1/B3: each phone alone disagrees; the server answer wins

    /// Olga's phone: her own VND rows, her categories (not Vladimir's
    /// personal one), her subscriptions; Vladimir's USD row only arrives via
    /// get_budget_member_expenses. Her same-name category can't be matched
    /// because the budget's category isn't visible to her → her own spend
    /// is lost locally.
    func test_partnerPhone_localDisagrees_serverWins() throws {
        let response = try Self.decodeServer()
        let server = try XCTUnwrap(response.budgets.first)
        let olgasTransactions = Self.allTransactions.filter { $0.userId == Self.olga }
        let olgasCategories = Self.allCategories.filter { $0.userId == Self.olga }
        let externalForOlga = [
            BudgetMath.ExternalSpendRow(txId: "t101", amountNative: 10, currency: "usd", txDate: "2026-11-17"),
        ]
        let input = BudgetMetricsResolver.Input(
            budgets: [Self.budget],
            transactions: olgasTransactions,
            subscriptions: Self.allSubscriptions,
            categories: olgasCategories,
            externalSpendByBudget: [Self.budgetId: externalForOlga],
            memberCountByBudget: [Self.budgetId: 2],
            currencyContext: Self.context,
            generation: 7,
            now: Self.now
        )

        let local = BudgetMath.compute(
            budget: Self.budget, transactions: olgasTransactions, subscriptions: Self.allSubscriptions,
            categories: olgasCategories, externalSpendRows: externalForOlga,
            currencyContext: Self.context, now: Self.now
        )
        XCTAssertEqual(local.spent, 82_569, "only Vladimir's row — Olga's own spend is lost on her phone (B1)")
        XCTAssertEqual(
            BudgetMetricsResolver.mismatches(for: Self.budget, server: server, input: input).map(\.field),
            ["spent"], "the cross-check must flag it (budget_integrity_mismatch)"
        )

        let snapshot = BudgetMetricsSnapshot(
            userId: Self.olga, day: "2026-11-17", fetchedAt: Self.now, generation: 7,
            budgets: [Self.budgetId: server],
            baselines: [Self.budgetId: try XCTUnwrap(BudgetMetricsResolver.baseline(for: Self.budget, server: server, input: input))]
        )
        let shown = try XCTUnwrap(BudgetMetricsResolver.resolve(input, snapshot: snapshot, lastFetchFailed: false)[Self.budgetId])
        XCTAssertEqual(shown.source, .server)
        XCTAssertEqual(shown.metrics.spent, 114_677, "Olga sees the same total as Vladimir")
        XCTAssertEqual(shown.metrics.subscriptionCommitted, 9_495)
        XCTAssertFalse(shown.isPartial)
    }

    /// Vladimir's phone: his own row + Olga's rows via the partner RPC
    /// (which name-matches) → spent agrees, but Olga's subscription is
    /// invisible to him, so the local daily allowance differs (B3).
    func test_ownerPhone_spentAgrees_subscriptionsOnlyOnServer() throws {
        let server = try XCTUnwrap(Self.decodeServer().budgets.first)
        let external = [
            BudgetMath.ExternalSpendRow(txId: "t102", amountNative: 100_000, currency: "vnd", txDate: "2026-11-16"),
            BudgetMath.ExternalSpendRow(txId: "t103", amountNative: 250_000, currency: "vnd", txDate: "2026-11-10"),
        ]
        let local = BudgetMath.compute(
            budget: Self.budget,
            transactions: Self.allTransactions.filter { $0.userId == Self.vladimir },
            subscriptions: [],
            categories: Self.allCategories.filter { $0.userId == Self.vladimir },
            externalSpendRows: external,
            currencyContext: Self.context, now: Self.now
        )
        XCTAssertEqual(local.spent, server.spent)
        XCTAssertEqual(local.carryIn, server.carryIn)
        XCTAssertEqual(local.subscriptionCommitted, 0)
        XCTAssertNotEqual(local.subscriptionCommitted, server.subscriptionCommitted)
    }

    // MARK: - Resolver: stale answers, edits, failures (B5)

    private func ownerInput(transactions: [Transaction], generation: UInt64, budget: Budget = BudgetServerParityTests.budget) -> BudgetMetricsResolver.Input {
        BudgetMetricsResolver.Input(
            budgets: [budget],
            transactions: transactions,
            subscriptions: [],
            categories: Self.allCategories,
            externalSpendByBudget: [:],
            memberCountByBudget: [Self.budgetId: 2],
            currencyContext: Self.context,
            generation: generation,
            now: Self.now
        )
    }

    private func snapshot(for input: BudgetMetricsResolver.Input) throws -> BudgetMetricsSnapshot {
        let server = try XCTUnwrap(Self.decodeServer().budgets.first)
        return BudgetMetricsSnapshot(
            userId: Self.vladimir, day: "2026-11-17", fetchedAt: Self.now, generation: input.generation,
            budgets: [Self.budgetId: server],
            baselines: [Self.budgetId: try XCTUnwrap(BudgetMetricsResolver.baseline(for: Self.budget, server: server, input: input))]
        )
    }

    func test_staleSnapshot_keepsPartnerPart_addsMyNewExpense() throws {
        let mine = Self.allTransactions.filter { $0.userId == Self.vladimir }
        let atFetch = ownerInput(transactions: mine, generation: 1)
        let snap = try snapshot(for: atFetch)

        // Offline: I add 200 ₽-worth ($2) on my card; the server can't be asked.
        let newTx = Self.tx("t200", user: Self.vladimir, account: Self.usdCard, category: Self.catV, amount: 2_00, date: "2026-11-17")
        let later = ownerInput(transactions: mine + [newTx], generation: 2)
        let shown = try XCTUnwrap(BudgetMetricsResolver.resolve(later, snapshot: snap, lastFetchFailed: true)[Self.budgetId])

        let twoDollars = NetWorthCalculator.convert(amount: 2_00, from: "USD", to: "RUB", rates: Self.context.fxRates)
        XCTAssertEqual(shown.source, .serverAdjusted)
        XCTAssertEqual(shown.metrics.spent, 114_677 + twoDollars, "last good partner total + my change, not a silent drop to my own rows")
        XCTAssertEqual(shown.spentToday, 82_569 + twoDollars)
        XCTAssertTrue(shown.isPartial, "server unreachable on a shared budget → marked partial (B5)")
        XCTAssertEqual(shown.metrics.carryIn, 19_729)
        XCTAssertEqual(shown.metrics.subscriptionCommitted, 9_495)
    }

    func test_editedBudget_fallsBackToLocal() throws {
        let mine = Self.allTransactions.filter { $0.userId == Self.vladimir }
        let snap = try snapshot(for: ownerInput(transactions: mine, generation: 1))
        var edited = Self.budget
        edited.amount = 5_000_00
        let shown = try XCTUnwrap(BudgetMetricsResolver.resolve(
            ownerInput(transactions: mine, generation: 2, budget: edited), snapshot: snap, lastFetchFailed: false
        )[Self.budgetId])
        XCTAssertEqual(shown.source, .local, "a snapshot computed for the old limit must not be shown")
        XCTAssertEqual(shown.metrics.effectiveLimit - shown.metrics.carryIn, 5_000_00)
        XCTAssertFalse(shown.isPartial)
    }

    func test_windowOver_staleSnapshotIgnored() throws {
        let mine = Self.allTransactions.filter { $0.userId == Self.vladimir }
        let snap = try snapshot(for: ownerInput(transactions: mine, generation: 1))
        var nextWeek = ownerInput(transactions: mine, generation: 2)
        nextWeek.now = BudgetMath.calendar.date(byAdding: .day, value: 7, to: Self.now)!
        let shown = try XCTUnwrap(BudgetMetricsResolver.resolve(nextWeek, snapshot: snap, lastFetchFailed: false)[Self.budgetId])
        XCTAssertEqual(shown.source, .local)
    }

    // MARK: - Decoding

    func test_decoding_toleratesMissingOptionalFields() throws {
        let minimal = """
        {"version":2,"today":"2026-11-17","budgets":[{"budget_id":"ABC","currency":"rub","period_start":"2026-11-01",
         "period_end":"2026-11-30","total_days":30,"elapsed_days":17,"remaining_days":14,"limit":100,
         "effective_limit":100,"spent":5,"remaining":95,"safe_to_spend_daily":6,"utilization":5,"future_field":true}]}
        """
        let decoded = try JSONDecoder().decode(ServerBudgetMetricsResponse.self, from: Data(minimal.utf8))
        let b = try XCTUnwrap(decoded.budgets.first)
        XCTAssertEqual(b.budgetId, "abc")
        XCTAssertEqual(b.currency, "RUB")
        XCTAssertEqual(b.carryIn, 0)
        XCTAssertTrue(b.byMember.isEmpty)
        XCTAssertNotNil(b.period)
    }
}
