import XCTest
@testable import AkifiIOS

/// Smoke tests for the savings-rate aggregator. The heavy lifting
/// happens inside `CashFlowEngine.monthlyBuckets`, which has its own
/// suite — here we just verify that the wrapper does the math we
/// claim (averaging over non-empty months, subtracting subs,
/// returning nil rate on zero income).
final class SavingsRateCalculatorTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 4, day: 15))!

    private func makeTx(
        id: String = UUID().uuidString,
        type: TransactionType,
        amount: Int64,
        date: String,
        accountId: String = "acct-1",
        currency: String = "RUB"
    ) -> Transaction {
        Transaction(
            id: id,
            userId: "user-1",
            accountId: accountId,
            amount: amount,
            currency: currency,
            description: nil,
            categoryId: nil,
            type: type,
            date: date,
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    /// No transactions → empty snapshot, savings rate is nil (no
    /// income to divide by).
    func test_emptyTransactions_returnsEmpty() {
        let s = SavingsRateCalculator.compute(
            transactions: [],
            subscriptions: [],
            now: now,
            calendar: cal
        )
        XCTAssertEqual(s.sampleMonths, 0)
        XCTAssertNil(s.savingsRate)
        XCTAssertEqual(s.avgMonthlyIncome, 0)
        XCTAssertEqual(s.avgMonthlyNet, 0)
    }

    /// One month, income 100k, expenses 70k → savings rate = 30%.
    func test_oneMonth_simpleSavingsRate() {
        let txs: [Transaction] = [
            makeTx(type: .income, amount: 100_000, date: "2026-03-15"),
            makeTx(type: .expense, amount: 70_000, date: "2026-03-20"),
        ]
        let s = SavingsRateCalculator.compute(
            transactions: txs,
            subscriptions: [],
            lookbackMonths: 3,
            now: now,
            calendar: cal
        )
        XCTAssertEqual(s.sampleMonths, 1)
        XCTAssertEqual(s.avgMonthlyIncome, 100_000)
        XCTAssertEqual(s.avgMonthlyExpense, 70_000)
        XCTAssertEqual(s.avgMonthlyNet, 30_000)
        XCTAssertEqual(s.savingsRate, Decimal(string: "0.3"))
    }

    /// Income only, no expenses → savings rate = 100%.
    func test_incomeOnly_savingsRateIsOne() {
        let txs: [Transaction] = [
            makeTx(type: .income, amount: 100_000, date: "2026-03-10"),
        ]
        let s = SavingsRateCalculator.compute(
            transactions: txs,
            subscriptions: [],
            now: now,
            calendar: cal
        )
        XCTAssertEqual(s.savingsRate, 1)
        XCTAssertEqual(s.avgMonthlyNet, 100_000)
    }

    /// Negative net (overspending) → negative rate.
    func test_overspending_negativeRate() {
        let txs: [Transaction] = [
            makeTx(type: .income, amount: 50_000, date: "2026-03-10"),
            makeTx(type: .expense, amount: 75_000, date: "2026-03-20"),
        ]
        let s = SavingsRateCalculator.compute(
            transactions: txs,
            subscriptions: [],
            now: now,
            calendar: cal
        )
        XCTAssertEqual(s.avgMonthlyNet, -25_000)
        XCTAssertEqual(s.savingsRate, Decimal(string: "-0.5"))
    }

    /// `sampleMonths` counts only months with activity, not the full
    /// lookback window. Drives the Confidence enum that gates the UI.
    func test_sparseHistory_samplesNonEmptyMonthsOnly() {
        let txs: [Transaction] = [
            // Only one month had any activity.
            makeTx(type: .income, amount: 100_000, date: "2026-02-10"),
            makeTx(type: .expense, amount: 50_000, date: "2026-02-15"),
        ]
        let s = SavingsRateCalculator.compute(
            transactions: txs,
            subscriptions: [],
            lookbackMonths: 6,
            now: now,
            calendar: cal
        )
        XCTAssertEqual(s.sampleMonths, 1)
        // 1 sample month → low confidence.
        XCTAssertEqual(s.confidence, .low)
    }
}
