import XCTest
@testable import AkifiIOS

// Regression tests for the 2026-11-27 review, money / currency / forms /
// settlement stream: M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M13 M15 M19, S4,
// and the budget-members parity with get_budget_metrics (20261127180000).

// MARK: - Fixtures

private enum F {
    /// USD-pivoted (1 USD = X), the `CurrencyManager.rates` convention.
    static let rates: [String: Double] = ["USD": 1.0, "RUB": 82.57, "EUR": 0.9]

    static func account(_ id: String, currency: String, owner: String = "u1") -> Account {
        Account(id: id, userId: owner, name: id, icon: "💳", color: "#000000",
                initialBalance: 0, currency: currency)
    }

    static func tx(
        _ id: String,
        account: String?,
        native: Int64,
        type: TransactionType,
        user: String = "u1",
        label: String? = nil,
        date: String = "2026-11-10",
        rawDateTime: String? = nil,
        categoryId: String? = nil,
        transferGroupId: String? = nil,
        autoTransferGroupId: String? = nil,
        paymentSource: String? = nil,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        fxRate: Decimal? = nil,
        merchant: String? = nil,
        createdAt: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: user, accountId: account,
            amount: native, amountNative: native, currency: label,
            foreignAmount: foreignAmount, foreignCurrency: foreignCurrency, fxRate: fxRate,
            description: nil, categoryId: categoryId, type: type, date: date,
            rawDateTime: rawDateTime,
            merchantName: merchant, merchantFuzzy: nil, transferGroupId: transferGroupId,
            paymentSourceAccountId: paymentSource,
            autoTransferGroupId: autoTransferGroupId,
            status: nil, createdAt: createdAt, updatedAt: nil
        )
    }

    static func category(_ id: String, name: String, owner: String = "u1", active: Bool = true) -> AkifiIOS.Category {
        AkifiIOS.Category(id: id, userId: owner, accountId: nil, name: name, icon: "🛒",
                          color: "#000000", type: .expense, isActive: active, createdAt: nil)
    }

    static func iso(_ raw: String) -> Date {
        AppDateFormatters.parseTimestamp(raw)!
    }

    static let moscow = TimeZone(identifier: "Europe/Moscow")!
}

// MARK: - M5 write-path rates

final class FXWriteRatesTests: XCTestCase {

    private let now = F.iso("2026-11-27T12:00:00Z")

    func test_M5_fallbackTableIsDisplayOnly() {
        let snapshot = FXRateSnapshot.fallback(["USD": 1, "RUB": 92.5])
        XCTAssertEqual(snapshot.rates["RUB"], 92.5, "display still has it")
        XCTAssertTrue(snapshot.writableRates(now: now).isEmpty, "a write never freezes the April table")
    }

    func test_M5_cacheYoungerThan48hIsWritable_olderIsNot() {
        let fresh = FXRateSnapshot.fromNetwork(F.rates, at: now.addingTimeInterval(-47 * 3600))
        XCTAssertEqual(fresh.writableRates(now: now)["RUB"], 82.57)

        let stale = FXRateSnapshot.fromNetwork(F.rates, at: now.addingTimeInterval(-49 * 3600))
        XCTAssertTrue(stale.writableRates(now: now).isEmpty)
        XCTAssertEqual(stale.rates["RUB"], 82.57, "stale quotes still render")
    }

    func test_M5_serverRowsAgeByTheirOwnUpdatedAt() {
        let snapshot = FXRateSnapshot.fromServer([
            ServerFXRateRow(code: "usd", perUsd: 1, updatedAt: "2026-11-27T11:00:00+00:00"),
            ServerFXRateRow(code: "RUB", perUsd: 82.57, updatedAt: "2026-11-27 10:02:31.123+00"),
            ServerFXRateRow(code: "KZT", perUsd: 445.5, updatedAt: "2026-11-16T00:02:31+00:00"),
        ])
        let writable = snapshot.writableRates(now: now)
        XCTAssertEqual(writable["USD"], 1)
        XCTAssertEqual(writable["RUB"], 82.57)
        XCTAssertNil(writable["KZT"], "a row the refresh job stopped updating ages out")
        XCTAssertEqual(snapshot.rates["KZT"], 445.5)
    }

    @MainActor
    func test_M5_writeWithFallbackOnlyCodeIsRefused() throws {
        let cm = CurrencyManager()
        var snapshot = FXRateSnapshot.fromNetwork(["USD": 1, "RUB": 82.57], at: Date())
        snapshot.rates["THB"] = 36.5   // fallback-only, no quote time
        cm.apply(snapshot)

        let write = cm.writeRates()
        XCTAssertEqual(
            try TransactionMath.convertForStorage(100, from: "USD", to: "RUB", rates: write), 8257
        )
        XCTAssertThrowsError(
            try TransactionMath.convertForStorage(100, from: "THB", to: "RUB", rates: write)
        ) { XCTAssertTrue($0 is MissingFXRateError) }
    }

    @MainActor
    func test_M5_instantStartRatesAreDisplayOnly() {
        // AppViewModel seeds `rates` from the cache before the network.
        let cm = CurrencyManager()
        cm.rates = F.rates
        XCTAssertTrue(cm.writeRates().isEmpty)
    }
}

// MARK: - S4 historical rates without a client key

final class HistoricalRatesTests: XCTestCase {

    func test_S4_noExchangeRateKeyInTheBundle() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "EXCHANGE_RATE_API_KEY"))
    }

    func test_S4_permanentCacheAnswersWithoutNetwork() async {
        let key = "cached_historical_exchange_rates"
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(try? JSONEncoder().encode(["USD-RUB-2026-11-17": 80.25]), forKey: key)

        let service = ExchangeRateService()
        let rate = await service.fetchHistoricalRate(from: "usd", to: "rub", day: "2026-11-17")
        XCTAssertEqual(rate, 80.25)
        let same = await service.fetchHistoricalRate(from: "EUR", to: "EUR", day: "2026-11-17")
        XCTAssertEqual(same, 1)
    }
}

// MARK: - M1 deposits

final class DepositLegTests: XCTestCase {

    func test_M1_foreignDepositDebitsSourceInSourceCurrency() throws {
        // $1 000 deposit from a rouble card: ~82 570 ₽, whatever the base currency.
        let leg = try DepositsViewModel.convertLeg(kopecks: 1_000_00, from: "USD", to: "rub", rates: F.rates)
        XCTAssertTrue(leg.isCrossCurrency)
        XCTAssertEqual(leg.kopecks, 82_570_00)
        XCTAssertEqual(NSDecimalNumber(decimal: leg.depositPerSource!).doubleValue, 1 / 82.57, accuracy: 1e-9)
    }

    func test_M1_missingRateRefusesInsteadOf1to1() {
        XCTAssertThrowsError(
            try DepositsViewModel.convertLeg(kopecks: 1_000_00, from: "USD", to: "KZT", rates: F.rates)
        ) { XCTAssertEqual($0 as? MissingFXRateError, MissingFXRateError(from: "USD", to: "KZT")) }
    }

    func test_M1_sameCurrencyPassesThrough() throws {
        let leg = try DepositsViewModel.convertLeg(kopecks: 1_234_56, from: "RUB", to: "rub", rates: [:])
        XCTAssertFalse(leg.isCrossCurrency)
        XCTAssertEqual(leg.kopecks, 1_234_56)
        XCTAssertNil(leg.depositPerSource)
    }

    func test_M1_returnLegConvertsDepositToReturnAccount() throws {
        // closeOrMature: €500 back to a USD card.
        let leg = try DepositsViewModel.convertLeg(kopecks: 500_00, from: "EUR", to: "USD", rates: F.rates)
        XCTAssertEqual(leg.kopecks, 555_56)
    }
}

// MARK: - M2 savings goal ↔ account

@MainActor
final class SavingsGoalLegsTests: XCTestCase {

    private let linked = F.account("savings", currency: "RUB")
    private let card = F.account("card", currency: "RUB")

    private func apply(_ legs: [SavingsViewModel.AccountLeg]) -> [Transaction] {
        legs.enumerated().map { i, leg in
            F.tx("t\(i)", account: leg.accountId, native: leg.amountNative.kopecks, type: leg.type,
                 transferGroupId: legs.count > 1 ? "g" : nil)
        }
    }

    func test_M2_withdrawalWithoutDestinationLowersTheLinkedAccount() throws {
        let legs = try SavingsViewModel.accountLegs(type: .withdrawal, amount: 10_000_00, linked: linked, counter: nil, rates: [:])
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(legs[0].type, .transfer)
        XCTAssertEqual(NativeBalance.net(accountId: "savings", transactions: apply(legs)), -10_000_00,
                       "it used to RAISE the account by the amount taken out")
    }

    func test_M2_contributionWithoutSourceCreatesNoMoney() throws {
        let legs = try SavingsViewModel.accountLegs(type: .contribution, amount: 10_000_00, linked: linked, counter: nil, rates: [:])
        XCTAssertTrue(legs.isEmpty)
    }

    func test_M2_contributionFromCardIsATransfer() throws {
        let legs = try SavingsViewModel.accountLegs(type: .contribution, amount: 10_000_00, linked: linked, counter: card, rates: [:])
        let rows = apply(legs)
        XCTAssertEqual(NativeBalance.net(accountId: "card", transactions: rows), -10_000_00)
        XCTAssertEqual(NativeBalance.net(accountId: "savings", transactions: rows), 10_000_00)
        XCTAssertTrue(rows.allSatisfy { $0.transferGroupId != nil }, "excluded from income / spending")
    }

    func test_M2_withdrawalToForeignCardConvertsTheLeg() throws {
        let usdCard = F.account("usd", currency: "USD")
        let legs = try SavingsViewModel.accountLegs(type: .withdrawal, amount: 8_257_00, linked: linked, counter: usdCard, rates: F.rates)
        let rows = apply(legs)
        XCTAssertEqual(NativeBalance.net(accountId: "savings", transactions: rows), -8_257_00)
        XCTAssertEqual(NativeBalance.net(accountId: "usd", transactions: rows), 100_00)
        XCTAssertThrowsError(
            try SavingsViewModel.accountLegs(type: .withdrawal, amount: 100, linked: linked, counter: usdCard, rates: [:])
        )
    }

    func test_M2_goalWithoutAccountTouchesNoAccount() throws {
        XCTAssertTrue(try SavingsViewModel.accountLegs(type: .withdrawal, amount: 100, linked: nil, counter: card, rates: [:]).isEmpty)
    }
}

// MARK: - M3 onboarding

final class OnboardingAccountTests: XCTestCase {
    @MainActor
    func test_M3_firstAccountUsesTheChosenCurrency() {
        XCTAssertEqual(AccountStepView.firstAccountCurrency(.usd), "usd")
        XCTAssertEqual(AccountStepView.firstAccountCurrency(.eur), "eur")
    }
}

// MARK: - M4 entry currency

final class EntryCurrencyStateTests: XCTestCase {

    func test_M4_followsEveryAccountSwitchUntilThePicker() {
        var state = EntryCurrencyState(.rub)
        state.load(.rub)                      // form opened (programmatic)
        state.follow(accountCurrency: .usd)   // «Карта USD»
        XCTAssertEqual(state.currency, .usd)
        state.follow(accountCurrency: .rub)   // «Наличные ₽» — stayed $ before
        XCTAssertEqual(state.currency, .rub)
        XCTAssertFalse(state.userPicked)
    }

    func test_M4_userChoiceSticks() {
        var state = EntryCurrencyState(.rub)
        state.userSelected(.eur)
        state.follow(accountCurrency: .usd)
        XCTAssertEqual(state.currency, .eur)
        XCTAssertTrue(state.userPicked)
    }

    func test_M4_loadNeverCountsAsTheUsersChoice() {
        var state = EntryCurrencyState(.rub)
        state.load(.usd)
        state.follow(accountCurrency: .rub)
        XCTAssertEqual(state.currency, .rub)
    }
}

// MARK: - M9 transfer direction

final class TransferDirectionTests: XCTestCase {
    func test_M9_directionComesFromTheType() {
        XCTAssertTrue(F.tx("a", account: "card", native: 500_00, type: .expense, transferGroupId: "g").movesMoneyOut,
                      "a positive expense leg goes OUT")
        XCTAssertFalse(F.tx("b", account: "cash", native: 500_00, type: .income, transferGroupId: "g").movesMoneyOut)
        XCTAssertTrue(F.tx("c", account: "card", native: -500_00, type: .transfer).movesMoneyOut)
        XCTAssertFalse(F.tx("d", account: "card", native: 500_00, type: .transfer).movesMoneyOut)
    }
}

// MARK: - M15 legacy one-row transfer

@MainActor
final class LegacyTransferEditTests: XCTestCase {

    private let rub = F.account("rub", currency: "RUB")

    func test_M15_outgoingRowIsUpdatedInPlaceKeepingItsSign() throws {
        let stored = F.tx("legacy", account: "rub", native: -500_00, type: .transfer)
        XCTAssertTrue(stored.isLegacySingleRowTransfer)
        let input = try TransferFormView.legacyRowUpdate(
            stored: stored, amountValue: 700, entryCurrency: .rub, account: rub,
            rates: [:], unchanged: false, date: "2026-11-27T10:00:00", description: nil
        )
        XCTAssertEqual(input.amount_native, -700)
        XCTAssertEqual(input.amount, -700)
        XCTAssertEqual(input.account_id, "rub")
        XCTAssertNil(input.type, "stays a single .transfer row — no new pair")
    }

    func test_M15_incomingForeignEntryConvertsAndStaysPositive() throws {
        let stored = F.tx("legacy", account: "rub", native: 300_00, type: .transfer)
        let input = try TransferFormView.legacyRowUpdate(
            stored: stored, amountValue: 10, entryCurrency: .usd, account: rub,
            rates: F.rates, unchanged: false, date: "2026-11-27T10:00:00", description: "x"
        )
        XCTAssertEqual(input.amount_native, Decimal(string: "825.7"))
        XCTAssertEqual(input.foreign_amount, 10)
        XCTAssertEqual(input.foreign_currency, "USD")
    }

    func test_M15_unchangedKeepsTheStoredAmount() throws {
        let stored = F.tx("legacy", account: "rub", native: -123_45, type: .transfer)
        let input = try TransferFormView.legacyRowUpdate(
            stored: stored, amountValue: Decimal(string: "123.45")!, entryCurrency: .rub, account: rub,
            rates: [:], unchanged: true, date: "2026-11-27T10:00:00", description: nil
        )
        XCTAssertEqual(input.amount_native, Decimal(string: "-123.45"))
    }
}

// MARK: - M13 subscription matcher currency

final class SubscriptionMatcherCurrencyTests: XCTestCase {

    private func netflix() -> SubscriptionTracker {
        SubscriptionTracker(
            id: "nf", userId: "u1", serviceName: "Netflix",
            amount: 999, currency: "USD",
            billingPeriod: .monthly, startDate: "2026-01-10",
            lastPaymentDate: nil, nextPaymentDate: nil,
            categoryId: nil, reminderDays: 1, iconColor: nil,
            isActive: true, status: .active
        )
    }

    func test_M13_accountCurrencyBeatsTheLegacyLabel() {
        // $9.99 on a USD card, legacy label RUB.
        let tx = F.tx("t", account: "usd-card", native: 999, type: .expense, label: "RUB", date: "2026-11-10", merchant: "NETFLIX.COM")
        let accounts = ["usd-card": F.account("usd-card", currency: "USD")]
        let scored = SubscriptionMatcher.score(transaction: tx, subscription: netflix(), baseCode: "RUB", accountsById: accounts)
        XCTAssertEqual(scored.amount, 50)
        XCTAssertGreaterThanOrEqual(scored.total, SubscriptionMatcher.matchThreshold)
    }

    func test_M13_foreignEntryInTheSubscriptionCurrencyMatches() {
        let tx = F.tx("t", account: "rub-card", native: 825_00, type: .expense, label: "RUB", date: "2026-11-10",
                      foreignAmount: Decimal(string: "9.99"), foreignCurrency: "USD", merchant: "Netflix")
        let accounts = ["rub-card": F.account("rub-card", currency: "RUB")]
        let scored = SubscriptionMatcher.score(transaction: tx, subscription: netflix(), baseCode: "RUB", accountsById: accounts)
        XCTAssertEqual(scored.amount, 50)
    }
}

// MARK: - M11 hidden categories + budget members parity

@MainActor
final class BudgetParityRulesTests: XCTestCase {

    private let period: (start: Date, end: Date) = {
        let cal = BudgetMath.calendar
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let end = cal.date(from: DateComponents(year: 2026, month: 11, day: 30))!
        return (start, end)
    }()

    private func budget(accountIds: [String]? = nil, categoryIds: [String]? = nil, owner: String = "u1") -> Budget {
        Budget(id: "b", userId: owner, accountIds: accountIds, amount: 10_000_00,
               billingPeriod: .monthly, categoryIds: categoryIds, currency: "RUB")
    }

    func test_M11_partnersHiddenCategoryStillCountsByName() {
        let categories = [
            F.category("mine", name: "Продукты"),
            F.category("partner", name: "Продукты", owner: "u2", active: false),
        ]
        let rows = [F.tx("t", account: "shared", native: 500_00, type: .expense, user: "u2", categoryId: "partner")]
        let spent = BudgetMath.spentAmount(
            budget: budget(categoryIds: ["mine"]), transactions: rows, period: period,
            categories: categories, currencyContext: ([:], [:], "RUB"),
            members: ["u1", "u2"]
        )
        XCTAssertEqual(spent, 500_00, "the server counts it — so must the fallback")
    }

    func test_M11_pickersOfferActiveCategoriesOnly() {
        let store = DataStore()
        store.categories = [F.category("a", name: "Еда"), F.category("h", name: "Старое", active: false)]
        XCTAssertEqual(store.displayCategories.map(\.id), ["a"])
    }

    func test_budgetMembers_nonMemberRowsCountOnlyOnLinkedAccounts() {
        let rows = [
            F.tx("member", account: "card", native: 100_00, type: .expense, user: "u2"),
            F.tx("stranger", account: "shared", native: 300_00, type: .expense, user: "x"),
        ]
        let members: Set<String> = ["u1", "u2"]
        let ctx: BudgetMath.CurrencyContext = ([:], [:], "RUB")

        XCTAssertEqual(
            BudgetMath.spentAmount(budget: budget(), transactions: rows, period: period, currencyContext: ctx, members: members),
            100_00, "no linked accounts: only members' rows (server, 20261127180000)"
        )
        XCTAssertEqual(
            BudgetMath.spentAmount(budget: budget(accountIds: ["shared"]), transactions: rows, period: period, currencyContext: ctx, members: members),
            300_00, "an explicitly linked account counts everyone's rows on it"
        )
    }

    func test_budgetMembers_ownerViewerAndMembers() {
        let ids = BudgetMath.memberIds(
            for: budget(owner: "OWNER"), viewerId: "Viewer",
            budgetMembers: [BudgetMember(id: "m", budgetId: "b", userId: "partner", role: .editor)]
        )
        XCTAssertEqual(ids, ["owner", "viewer", "partner"])
    }

    func test_budgetMembers_resolverAppliesTheRule() {
        let b = budget()
        let rows = [
            F.tx("mine", account: "card", native: 100_00, type: .expense, user: "u1", date: AppDateFormatters.isoDate.string(from: Date())),
            F.tx("stranger", account: "shared", native: 300_00, type: .expense, user: "x", date: AppDateFormatters.isoDate.string(from: Date())),
        ]
        let input = BudgetMetricsResolver.Input(
            budgets: [b], transactions: rows, subscriptions: [], categories: [],
            externalSpendByBudget: [:], memberCountByBudget: [:],
            currencyContext: ([:], [:], "RUB"), generation: 1, now: Date(),
            memberIdsByBudget: ["b": ["u1"]]
        )
        let resolved = BudgetMetricsResolver.resolve(input, snapshot: nil, lastFetchFailed: false)
        XCTAssertEqual(resolved["b"]?.metrics.spent, 100_00)
    }
}

// MARK: - M8 PDF budgets + home budget hint

@MainActor
final class BudgetReportingTests: XCTestCase {

    private func metrics(spent: Int64, limit: Int64) -> BudgetMetrics {
        let cal = BudgetMath.calendar
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 20, to: start)!
        return BudgetMath.assemble(limit: limit, carryIn: 0, spent: spent, subscriptionCommitted: 0,
                                   period: (start, end), today: start)
    }

    func test_M8_pdfLinesUseResolvedMetricsAndBudgetCurrency() {
        let usdBudget = Budget(id: "b", userId: "u1", budgetName: "Travel", amount: 500_00,
                               billingPeriod: .monthly, currency: "USD")
        let resolved = ResolvedBudgetMetrics(
            budget: usdBudget, metrics: metrics(spent: 320_00, limit: 500_00),
            source: .server, isPartial: false, server: nil, spentToday: 0
        )
        let lines = PDFReportGenerator.budgetLines(
            budgets: [usdBudget], resolved: ["b": resolved],
            currencyContext: ([:], [:], "RUB"), periodLabel: { _, _ in "1 – 30 Nov" }
        )
        XCTAssertEqual(lines, [PDFReportGenerator.BudgetLine(
            name: "Travel", spent: 320_00, limit: 500_00, utilization: 64, currency: "USD", periodLabel: "1 – 30 Nov"
        )])
    }

    func test_M8_homeBudgetHintReadsResolvedMetrics() {
        let b = Budget(id: "b", userId: "u1", budgetName: "Food", amount: 1_000_00, billingPeriod: .monthly, currency: "RUB")
        func insights(_ m: BudgetMetrics) -> [InsightEngine.Insight] {
            InsightEngine.generate(InsightEngine.Input(
                transactions: [], categories: [], budgets: [b], subscriptions: [],
                formatAmount: { "\($0)" }, budgetMetrics: ["b": m]
            )).filter { $0.kind == .budgetWarning }
        }
        XCTAssertEqual(insights(metrics(spent: 900_00, limit: 1_000_00)).count, 1,
                       "the partner's spending the server counted is there although no local row is")
        XCTAssertTrue(insights(metrics(spent: 100_00, limit: 1_000_00)).isEmpty)
    }
}

// MARK: - M6 / M7 / M10 settlements

final class SettlementFrameTests: XCTestCase {

    func test_M6_settledBadgeComparesInOneFrame() {
        // Moscow: expense at 19:00 local (stored "19:00" labelled UTC),
        // settlement at 21:00 local = 18:00Z.
        let watermark = F.iso("2026-11-27T18:00:00Z")
        let evening = F.tx("e", account: "s", native: 100, type: .expense, date: "2026-11-27", rawDateTime: "2026-11-27T19:00:00+00:00")
        XCTAssertTrue(SharedAccountDetailView.isCoveredBySettlement(evening, watermark: watermark, timeZone: F.moscow))
        let later = F.tx("l", account: "s", native: 100, type: .expense, date: "2026-11-27", rawDateTime: "2026-11-27T22:00:00+00:00")
        XCTAssertFalse(SharedAccountDetailView.isCoveredBySettlement(later, watermark: watermark, timeZone: F.moscow))
    }

    func test_M6_settlementAfterMidnightBelongsToTheNewLocalMonth() {
        // 01:30 on 1 December in Moscow = 22:30Z on 30 November.
        let now = F.iso("2026-11-30T22:30:00Z")
        let settlement = Settlement(
            id: "s", sharedAccountId: "a", fromUserId: "A", toUserId: "B", amount: 100,
            currency: "RUB", periodStart: "2026-12-01", periodEnd: "2026-12-01",
            settledAt: "2026-11-30T22:30:00Z", settledBy: "A", createdAt: nil
        )
        let december = SettlementPeriod.thisMonth.instantInterval(now: now, timeZone: F.moscow)
        XCTAssertEqual(SettlementViewModel.settlements([settlement], in: december).count, 1)
        let november = SettlementPeriod.lastMonth.instantInterval(now: now, timeZone: F.moscow)
        XCTAssertTrue(SettlementViewModel.settlements([settlement], in: november).isEmpty)
    }

    func test_M6_transactionListMonthIsTheLocalMonth() {
        let now = F.iso("2026-11-30T22:30:00Z")
        let interval = SettlementPeriod.thisMonth.transactionInterval(now: now, timeZone: F.moscow)
        XCTAssertTrue(interval.contains(AppDateFormatters.utcDate.date(from: "2026-12-01")!))
        XCTAssertFalse(interval.contains(AppDateFormatters.utcDate.date(from: "2026-11-30")!))
    }

    func test_M7_noSuggestionsWithoutConfirmedData() {
        XCTAssertEqual(SettlementViewModel.reliability(serverOK: true, settlementsLoaded: true, marksLoaded: true), .confirmed)
        XCTAssertEqual(SettlementViewModel.reliability(serverOK: false, settlementsLoaded: true, marksLoaded: true), .approximate)
        XCTAssertEqual(SettlementViewModel.reliability(serverOK: true, settlementsLoaded: false, marksLoaded: true), .approximate)
        XCTAssertEqual(SettlementViewModel.reliability(serverOK: false, settlementsLoaded: false, marksLoaded: false), .unavailable)

        let balances = [
            SettlementCalculator.MemberBalance(userId: "A", contributed: 0, fairShare: 5_858_92),
            SettlementCalculator.MemberBalance(userId: "B", contributed: 11_717_84, fairShare: 5_858_92),
        ]
        XCTAssertEqual(SettlementViewModel.suggestions(from: balances, reliability: .confirmed).count, 1)
        XCTAssertTrue(SettlementViewModel.suggestions(from: balances, reliability: .approximate).isEmpty)
        XCTAssertTrue(SettlementViewModel.suggestions(from: balances, reliability: .unavailable).isEmpty)
    }

    func test_M10_nonMemberCardOwnerIsNeverThePayer() {
        // A pays from card C that X (not a member of the shared account)
        // shares with A. The server credits A (leg author); so must we.
        let group = "g"
        let rows = [
            F.tx("main", account: "shared", native: 100_00, type: .expense, user: "A", date: "2026-11-10",
                 autoTransferGroupId: group, paymentSource: "C"),
            F.tx("out", account: "C", native: 100_00, type: .expense, user: "A", date: "2026-11-10",
                 transferGroupId: group, autoTransferGroupId: group),
            F.tx("in", account: "shared", native: 100_00, type: .income, user: "A", date: "2026-11-10",
                 transferGroupId: group, autoTransferGroupId: group),
        ]
        let balances = SettlementCalculator.compute(
            sharedAccountId: "shared", transactions: rows, memberUserIds: ["A", "B"],
            personalAccountsByUser: ["X": ["C"]],
            period: DateInterval(start: .distantPast, end: .distantFuture)
        )
        XCTAssertEqual(balances.first { $0.userId == "A" }?.contributed, 100_00)
        XCTAssertNil(balances.first { $0.userId == "X" })
    }

    func test_M10_mismatchEventOncePerAccountPerDay() {
        let suite = "M10-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        XCTAssertTrue(SettlementViewModel.shouldReportMismatch(accountId: "a", now: now, defaults: defaults))
        XCTAssertFalse(SettlementViewModel.shouldReportMismatch(accountId: "a", now: now, defaults: defaults))
        XCTAssertTrue(SettlementViewModel.shouldReportMismatch(accountId: "b", now: now, defaults: defaults))
        XCTAssertTrue(SettlementViewModel.shouldReportMismatch(accountId: "a", now: now.addingTimeInterval(86_400 * 2), defaults: defaults))
    }
}

// MARK: - M19 bank import keeps kopecks

final class BankImportAmountTests: XCTestCase {
    @MainActor
    func test_M19_statementAmountsKeepTheirKopecks() {
        XCTAssertEqual(BankImportView.storedAmount(1234.56, accountCurrency: "RUB"), Decimal(string: "1234.56"))
        XCTAssertEqual(BankImportView.storedAmount(4.99, accountCurrency: "USD"), Decimal(string: "4.99"))
        XCTAssertEqual(BankImportView.storedAmount(0.3, accountCurrency: "usd"), Decimal(string: "0.3"))
        XCTAssertEqual(BankImportView.storedAmount(1500, accountCurrency: "JPY"), 1500)
        XCTAssertEqual(BankImportView.storedAmount(4.99, accountCurrency: nil), Decimal(string: "4.99"))
    }
}
