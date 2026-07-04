import XCTest
@testable import AkifiIOS

/// `AnalyticsViewModel.cashflowData` — bucketing for the cashflow chart —
/// and `BudgetMath.minDailySafeToSpend` (extracted from DailyLimitWidget).
@MainActor
final class AnalyticsViewModelTests: XCTestCase {

    private lazy var store: DataStore = {
        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = ["USD": 1.0, "RUB": 100.0]
        store.currencyManager = cm
        store.accounts = [Account(
            id: "acc-1", userId: "u1", name: "Карта", icon: "💳", color: "#3B82F6",
            initialBalance: 0, currency: "RUB"
        )]
        store.rebuildCaches()
        return store
    }()

    private func makeTx(
        id: String,
        amountNative: Int64,
        type: TransactionType,
        date: String,
        transferGroupId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: "acc-1",
            amount: amountNative, amountNative: amountNative, currency: "RUB",
            description: nil, categoryId: nil, type: type,
            date: date, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: transferGroupId, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func dateStr(daysAgo: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!)
    }

    // MARK: - cashflowData

    func test_cashflowData_bucketsChronologically() {
        // Feed days out of order — output buckets must be sorted by date,
        // not by dictionary order (the old implementation's bar-shuffle bug).
        let vm = AnalyticsViewModel()
        vm.selectedPeriod = .week
        let txs = [
            makeTx(id: "t1", amountNative: 100_00, type: .expense, date: dateStr(daysAgo: 1)),
            makeTx(id: "t2", amountNative: 200_00, type: .expense, date: dateStr(daysAgo: 5)),
            makeTx(id: "t3", amountNative: 300_00, type: .expense, date: dateStr(daysAgo: 3))
        ]

        let points = vm.cashflowData(from: txs, dataStore: store)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.expense), [200, 300, 100], "oldest bucket first, newest last")
    }

    func test_cashflowData_separatesIncomeAndExpense() {
        let vm = AnalyticsViewModel()
        vm.selectedPeriod = .week
        let day = dateStr(daysAgo: 2)
        let txs = [
            makeTx(id: "t1", amountNative: 500_00, type: .income, date: day),
            makeTx(id: "t2", amountNative: 150_00, type: .expense, date: day)
        ]

        let points = vm.cashflowData(from: txs, dataStore: store)

        XCTAssertEqual(points.count, 1, "same day folds into one bucket")
        XCTAssertEqual(points[0].income, 500)
        XCTAssertEqual(points[0].expense, 150)
    }

    func test_cashflowData_excludesTransfers() {
        let vm = AnalyticsViewModel()
        vm.selectedPeriod = .week
        let txs = [
            makeTx(id: "t1", amountNative: 100_00, type: .expense, date: dateStr(daysAgo: 1)),
            makeTx(id: "t2", amountNative: 900_00, type: .expense, date: dateStr(daysAgo: 1), transferGroupId: "g1"),
            makeTx(id: "t3", amountNative: 900_00, type: .transfer, date: dateStr(daysAgo: 1))
        ]

        let points = vm.cashflowData(from: txs, dataStore: store)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].expense, 100, "transfer legs must not inflate cashflow")
    }

    func test_cashflowData_monthPeriod_bucketsByWeek() {
        let vm = AnalyticsViewModel()
        vm.selectedPeriod = .month
        // Two txs in the same ISO week, one clearly in another week.
        let txs = [
            makeTx(id: "t1", amountNative: 100_00, type: .expense, date: dateStr(daysAgo: 0)),
            makeTx(id: "t2", amountNative: 200_00, type: .expense, date: dateStr(daysAgo: 14))
        ]

        let points = vm.cashflowData(from: txs, dataStore: store)

        XCTAssertEqual(points.count, 2, "14 days apart always lands in different week buckets")
        XCTAssertEqual(points.first?.expense, 200, "older week first")
    }

    // MARK: - minDailySafeToSpend

    private var defaultContext: BudgetMath.CurrencyContext { ([:], [:], "RUB") }

    private func makeBudget(id: String, amount: Int64) -> Budget {
        // Fresh created_at → 30-day rolling period is current → remainingDays > 0.
        let iso = ISO8601DateFormatter().string(from: Date())
        return Budget(
            id: id, userId: "u1", amount: amount, billingPeriod: .monthly,
            createdAt: iso
        )
    }

    func test_minDailySafeToSpend_noBudgets_zero() {
        XCTAssertEqual(
            BudgetMath.minDailySafeToSpend(budgets: [], transactions: [], currencyContext: defaultContext),
            0
        )
    }

    func test_minDailySafeToSpend_takesMostRestrictiveBudget() {
        let generous = makeBudget(id: "b1", amount: 300_000_00)
        let tight = makeBudget(id: "b2", amount: 3_000_00)

        let daily = BudgetMath.minDailySafeToSpend(
            budgets: [generous, tight], transactions: [], currencyContext: defaultContext
        )

        // The tight budget dominates: 3 000 ₽ over its remaining days is
        // far below the generous one. Exact remaining days depend on today,
        // so assert the bound instead of an exact figure.
        XCTAssertGreaterThan(daily, 0)
        XCTAssertLessThanOrEqual(daily, 3_000, "min across budgets can never exceed the tight budget's whole amount")
    }

    func test_minDailySafeToSpend_neverNegative() {
        let budget = makeBudget(id: "b1", amount: 1_000_00)
        // Overspent: expense far above the limit inside the current period.
        let txs = [makeTx(id: "t1", amountNative: 50_000_00, type: .expense, date: dateStr(daysAgo: 0))]

        let daily = BudgetMath.minDailySafeToSpend(
            budgets: [budget], transactions: txs, currencyContext: defaultContext
        )

        XCTAssertEqual(daily, 0, "overspent budget clamps to zero, not negative")
    }
}
