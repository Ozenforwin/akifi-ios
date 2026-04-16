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
        date: String
    ) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: "a1",
            amount: amount, currency: "RUB", description: nil,
            categoryId: "c1", type: type, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func sub(amount: Int64, period: BillingPeriod, status: SubscriptionTrackerStatus = .active) -> SubscriptionTracker {
        SubscriptionTracker(
            id: UUID().uuidString, userId: "u1", serviceName: "Sub",
            amount: amount, currency: "RUB",
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
        let transactions = [
            tx(id: "1", amount: 100_000_00, type: .income, date: "2026-03-01"),
            tx(id: "2", amount: 50_000_00, type: .expense, date: "2026-03-15")
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
        // Net = income - expense - subs (over 3 months averaged)
        // income avg = 100_000/3 ≈ 33_333
        // expense avg = 50_000/3 ≈ 16_666
        // net = 33_333 - 16_666 - 1000 = 15_667 roughly
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
}
