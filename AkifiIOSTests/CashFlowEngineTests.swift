import XCTest
@testable import AkifiIOS

final class CashFlowEngineTests: XCTestCase {

    private var calendar: Calendar!
    private var fixedNow: Date!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        calendar = cal
        // Fixed "now": 2026-04-16
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 16
        fixedNow = cal.date(from: comps)!
    }

    // MARK: - Factories

    private func tx(
        id: String,
        amount: Int64,
        type: TransactionType,
        date: String,
        merchant: String? = nil,
        currency: String = "RUB"
    ) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: "a1",
            amount: amount, currency: currency, description: nil,
            categoryId: "c1", type: type, date: date,
            merchantName: merchant, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func sub(
        amount: Int64,
        period: BillingPeriod,
        status: SubscriptionTrackerStatus = .active,
        serviceName: String = "Sub",
        currency: String = "RUB"
    ) -> SubscriptionTracker {
        SubscriptionTracker(
            id: UUID().uuidString, userId: "u1", serviceName: serviceName,
            amount: amount, currency: currency,
            billingPeriod: period, startDate: "2026-01-01",
            lastPaymentDate: nil, nextPaymentDate: nil,
            categoryId: nil, reminderDays: 1, iconColor: nil,
            isActive: status == .active, status: status
        )
    }

    // MARK: - normalizeToMonthly

    func testNormalizeToMonthly_Weekly_MultipliesByApproxFour() {
        let result = CashFlowEngine.normalizeToMonthly(amount: 100_00, period: .weekly)
        XCTAssertEqual(result, 43333)
    }

    func testNormalizeToMonthly_Yearly_DividesByTwelve() {
        XCTAssertEqual(CashFlowEngine.normalizeToMonthly(amount: 12_000_00, period: .yearly), 1_000_00)
    }

    // MARK: - forecast — empty

    func testForecast_EmptyHistory_ZeroAverages() {
        let result = CashFlowEngine.forecast(
            startingBalance: 10_000_00,
            transactions: [],
            subscriptions: [],
            monthsAhead: 3,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.avgMonthlyIncome, 0)
        XCTAssertEqual(result.avgMonthlyExpense, 0)
        XCTAssertEqual(result.sampleMonths, 0, "Empty history → zero non-empty sample months")
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.points.count, 3)
        XCTAssertEqual(result.points.first?.projectedBalance, 10_000_00)
    }

    // MARK: - forecast — with history

    func testForecast_ThreeMonthsHistory_AveragesCorrectly() {
        // March 2026: income 100_000, expense 70_000
        // February 2026: income 100_000, expense 80_000
        // January 2026: income 100_000, expense 60_000
        let transactions = [
            tx(id: "1", amount: 100_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 70_000_00, type: .expense, date: "2026-03-15"),
            tx(id: "3", amount: 100_000_00, type: .income, date: "2026-02-01"),
            tx(id: "4", amount: 80_000_00, type: .expense, date: "2026-02-15"),
            tx(id: "5", amount: 100_000_00, type: .income, date: "2026-01-01"),
            tx(id: "6", amount: 60_000_00, type: .expense, date: "2026-01-15")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 50_000_00,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 3,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )

        XCTAssertEqual(result.avgMonthlyIncome, 100_000_00)
        XCTAssertEqual(result.avgMonthlyExpense, 70_000_00)
        XCTAssertEqual(result.sampleMonths, 3)
        XCTAssertEqual(result.confidence, .medium)
    }

    func testForecast_WithSubscriptions_DeductsMonthlyCost() {
        // Sub serviceName "Sub" won't match merchant "Store", so
        // expense stays in the averages.
        let transactions = [
            tx(id: "1", amount: 100_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 50_000_00, type: .expense, date: "2026-03-15", merchant: "Store")
        ]
        let subs = [sub(amount: 1_000_00, period: .monthly)]
        let result = CashFlowEngine.forecast(
            startingBalance: 10_000_00,
            transactions: transactions,
            subscriptions: subs,
            monthsAhead: 1,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )

        XCTAssertEqual(result.monthlySubscriptionCost, 1_000_00)
        // Net = income - expense - subs
        XCTAssertLessThan(result.netMonthly, result.avgMonthlyIncome - result.avgMonthlyExpense)
    }

    func testForecast_PausedSubscriptions_Excluded() {
        let subs = [
            sub(amount: 1_000_00, period: .monthly, status: .active),
            sub(amount: 500_00, period: .monthly, status: .paused),
            sub(amount: 500_00, period: .monthly, status: .cancelled)
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 0,
            transactions: [],
            subscriptions: subs,
            monthsAhead: 1,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.monthlySubscriptionCost, 1_000_00)
    }

    func testForecast_ConfidenceScales() {
        XCTAssertEqual(CashFlowEngine.confidence(for: 0), .low)
        XCTAssertEqual(CashFlowEngine.confidence(for: 1), .low)
        XCTAssertEqual(CashFlowEngine.confidence(for: 2), .medium)
        XCTAssertEqual(CashFlowEngine.confidence(for: 3), .medium)
        XCTAssertEqual(CashFlowEngine.confidence(for: 4), .high)
    }

    func testForecast_Horizon_ClampedToValidRange() {
        let result = CashFlowEngine.forecast(
            startingBalance: 0,
            transactions: [],
            subscriptions: [],
            monthsAhead: 50,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.points.count, 12)
    }

    func testForecast_ProducesEndOfMonthDates() {
        let result = CashFlowEngine.forecast(
            startingBalance: 0,
            transactions: [],
            subscriptions: [],
            monthsAhead: 1,
            now: fixedNow,
            calendar: calendar
        )
        guard let point = result.points.first else { return XCTFail("no point") }
        let comps = calendar.dateComponents([.year, .month, .day], from: point.date)
        // May has 31 days
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 31)
    }

    // MARK: - variance

    func testVariance_SingleValue_Zero() {
        XCTAssertEqual(CashFlowEngine.variance(values: [100], mean: 100), 0)
    }

    func testVariance_IdenticalValues_Zero() {
        XCTAssertEqual(CashFlowEngine.variance(values: [50, 50, 50], mean: 50), 0)
    }

    func testVariance_SimpleCase_Correct() {
        // values [10, 20, 30], mean = 20 → variance = ((10-20)² + (20-20)² + (30-20)²) / 2 = 100
        let result = CashFlowEngine.variance(values: [10, 20, 30], mean: 20)
        XCTAssertEqual(result, 100)
    }

    // MARK: - Bug 1: sampleMonths counts only non-empty months

    func testConfidence_CountsOnlyNonEmptyMonths() {
        // Only March 2026 has data → sampleMonths should be 1 → .low
        let transactions = [
            tx(id: "1", amount: 50_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 20_000_00, type: .expense, date: "2026-03-15", merchant: "Store")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 100_000_00,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 1,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.sampleMonths, 1, "Only one month had transactions")
        XCTAssertEqual(result.confidence, .low, "One month → low confidence")
    }

    func testAverages_DividedByNonEmptyMonths() {
        // Only one month with data; historyMonths=3 would have divided by 3.
        // New behavior: divide by 1.
        let transactions = [
            tx(id: "1", amount: 90_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 30_000_00, type: .expense, date: "2026-03-15", merchant: "Store")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 0,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 1,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.avgMonthlyIncome, 90_000_00, "Average divided by non-empty count (1), not window size (3)")
        XCTAssertEqual(result.avgMonthlyExpense, 30_000_00)
    }

    func testFourNonEmptyMonths_HighConfidence() {
        let transactions = [
            tx(id: "1", amount: 10_000_00, type: .income, date: "2026-03-10"),
            tx(id: "2", amount: 10_000_00, type: .income, date: "2026-02-10"),
            tx(id: "3", amount: 10_000_00, type: .income, date: "2026-01-10"),
            tx(id: "4", amount: 10_000_00, type: .income, date: "2025-12-10")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 0,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 1,
            historyMonths: 6,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.sampleMonths, 4)
        XCTAssertEqual(result.confidence, .high)
    }

    // MARK: - Bug 3: fallback stdDev when sampleMonths < 2

    func testFallbackStdDev_SingleMonth_ProducesNonZeroBand() {
        let transactions = [
            tx(id: "1", amount: 100_000_00, type: .income, date: "2026-03-10"),
            tx(id: "2", amount: 40_000_00, type: .expense, date: "2026-03-20", merchant: "Store")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 100_000_00,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 1,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        guard let point = result.points.first else { return XCTFail("no point") }
        // With fallback stdDev = 15% * 40_000_00 = 6_000_00, optimistic must exceed pessimistic.
        XCTAssertGreaterThan(point.optimistic, point.pessimistic,
            "Single-month history must still show a non-collapsed confidence band")
    }

    // MARK: - Bug 4: subscriptions not double-counted

    func testSubscriptions_NotDoubleCounted() {
        // Active Netflix sub @ 499 rub/mo. History contains one matching "Netflix"
        // expense at 500 rub (within ±5%). That expense should be stripped from
        // the averages; only monthlySubscriptionCost should carry subs.
        let transactions = [
            tx(id: "1", amount: 100_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 500_00, type: .expense, date: "2026-03-15", merchant: "Netflix Inc")
        ]
        let subs = [sub(amount: 499_00, period: .monthly, serviceName: "Netflix")]
        let result = CashFlowEngine.forecast(
            startingBalance: 10_000_00,
            transactions: transactions,
            subscriptions: subs,
            monthsAhead: 1,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )

        XCTAssertEqual(result.avgMonthlyExpense, 0, "Netflix expense should be filtered out of history")
        XCTAssertEqual(result.monthlySubscriptionCost, 499_00)
        // netMonthly = 100_000_00 - 0 - 499_00 = 99_501_00
        XCTAssertEqual(result.netMonthly, 99_501_00)
    }

    func testSubscriptions_NonMatching_NotFiltered() {
        // Sub is for Netflix but expense is at a different store — must remain.
        let transactions = [
            tx(id: "1", amount: 100_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 25_000_00, type: .expense, date: "2026-03-15", merchant: "Groceries")
        ]
        let subs = [sub(amount: 499_00, period: .monthly, serviceName: "Netflix")]
        let result = CashFlowEngine.forecast(
            startingBalance: 0,
            transactions: transactions,
            subscriptions: subs,
            monthsAhead: 1,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.avgMonthlyExpense, 25_000_00, "Non-matching expense must remain in averages")
        XCTAssertEqual(result.monthlySubscriptionCost, 499_00)
    }

    // MARK: - monthsUntilEmpty (new)

    func testMonthsUntilEmpty_NegativeNet_ReturnsBalanceDividedByBurn() {
        // Single month of net-negative history: income 10k, expense 20k, no subs.
        // Starting balance 100k, burn 10k/mo → ~10 months.
        let transactions = [
            tx(id: "1", amount: 10_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 20_000_00, type: .expense, date: "2026-03-15", merchant: "Store")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 100_000_00,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 3,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertEqual(result.monthsUntilEmpty, 10)
    }

    func testMonthsUntilEmpty_PositiveNet_ReturnsNil() {
        let transactions = [
            tx(id: "1", amount: 50_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 10_000_00, type: .expense, date: "2026-03-15", merchant: "Store")
        ]
        let result = CashFlowEngine.forecast(
            startingBalance: 100_000_00,
            transactions: transactions,
            subscriptions: [],
            monthsAhead: 3,
            historyMonths: 3,
            now: fixedNow,
            calendar: calendar
        )
        XCTAssertNil(result.monthsUntilEmpty)
    }
}
