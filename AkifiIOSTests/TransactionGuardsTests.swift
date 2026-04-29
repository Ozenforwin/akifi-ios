import XCTest
@testable import AkifiIOS

/// Pure-function tests for the large-expense confirmation guard. No
/// XCUI, no @Observable, no DataStore: we feed `TransactionGuards`
/// hand-crafted fixtures and assert the boolean it returns.
///
/// Rate fixture is USD-pivoted (same convention as `CurrencyManager`):
///   1 USD ≈ 92.5 RUB / 25 400 VND / 0.92 EUR
/// All amounts in fixtures are in main units (Decimal), not kopecks —
/// matches the contract on `inputAmount`.
final class TransactionGuardsTests: XCTestCase {

    // MARK: - Fixtures

    private let rates: [String: Decimal] = [
        "USD": Decimal(1),
        "RUB": Decimal(92.5),
        "VND": Decimal(25_400),
        "EUR": Decimal(string: "0.92")!
    ]

    private let baseCode = "RUB"

    /// RUB account so the fixture transactions map cleanly to base.
    private let rubAccount = Account(
        id: "acc-rub",
        userId: "u1",
        name: "Семейный",
        icon: "🏠",
        color: "#3B82F6",
        initialBalance: 0,
        currency: "RUB"
    )

    private var accountsById: [String: Account] {
        [rubAccount.id: rubAccount]
    }

    private var context: TransactionMath.CurrencyContext {
        (accountsById: accountsById, fxRates: rates, baseCode: baseCode)
    }

    /// Fixed "now" so the lookback window math is deterministic.
    private let now: Date = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: "2026-04-20")!
    }()

    /// Build a list of expense transactions with given amounts (RUB
    /// rubles, main units), all dated within the lookback window. We
    /// stamp them on consecutive recent days so date filtering
    /// inclusively picks all of them up.
    private func makeExpenses(rubAmounts: [Decimal]) -> [Transaction] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return rubAmounts.enumerated().map { idx, rub in
            let day = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: -(idx + 1), to: now)!
            let kopecks = NSDecimalNumber(decimal: rub * 100).int64Value
            return Transaction(
                id: "tx-\(idx)",
                userId: "u1",
                accountId: rubAccount.id,
                amount: kopecks,
                amountNative: kopecks,
                currency: "RUB",
                description: nil,
                categoryId: nil,
                type: .expense,
                date: f.string(from: day),
                merchantName: nil,
                merchantFuzzy: nil,
                transferGroupId: nil,
                status: nil,
                createdAt: nil,
                updatedAt: nil
            )
        }
    }

    // MARK: - Trigger cases

    /// Median of [1000, 1000, 1000] = 1000 ₽. 6000 ₽ > 5×1000 + above
    /// the floor → alert fires.
    func test_expenseFarAboveMedian_triggersConfirmation() {
        let txs = makeExpenses(rubAmounts: [1000, 1000, 1000])
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(6_000),
            inputCurrency: "RUB",
            type: .expense,
            allTransactions: txs,
            context: context,
            now: now
        )
        XCTAssertTrue(decision.shouldConfirm)
        XCTAssertEqual(decision.medianInBaseDisplay, Decimal(1000))
        XCTAssertEqual(decision.inputInBaseDisplay, Decimal(6_000))
    }

    /// Mirror of the user's reported bug: typing 350 000 ₽ on a
    /// VND-account where they meant 350 000 ₫. Median 2 000 ₽,
    /// 350 000 ₽ obviously qualifies. We pass RUB as the entry
    /// currency to simulate the misclick — guard fires.
    func test_expenseInWrongCurrency_triggersConfirmation() {
        let txs = makeExpenses(rubAmounts: [2_000, 1_500, 2_500])
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(350_000),
            inputCurrency: "RUB",
            type: .expense,
            allTransactions: txs,
            context: context,
            now: now
        )
        XCTAssertTrue(decision.shouldConfirm)
    }

    // MARK: - Skip cases

    /// 500 ₽ over a 50 ₽ median is technically 10×, but the absolute
    /// figure is below the 100 ₽ floor on the median — wait, 500 > 100,
    /// so this WOULD fire. We instead test the actual guard: input
    /// 200 ₽ with median 50 ₽ — 200 > 5×50=250 fails too. The clean
    /// way to pin the floor: input 80 ₽, median 5 ₽ → 80 > 5×5=25 yes,
    /// but 80 < 100 floor → guard fails.
    func test_expenseBelowMinThreshold_skipsAlert() {
        let txs = makeExpenses(rubAmounts: [5, 5, 5, 5])
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(80),
            inputCurrency: "RUB",
            type: .expense,
            allTransactions: txs,
            context: context,
            now: now
        )
        XCTAssertFalse(decision.shouldConfirm,
                       "Below-floor input should never trigger the alert.")
    }

    /// Income is allowed to be huge (paycheck, bonus, refund) — we
    /// must never block income saves.
    func test_incomeNeverTriggers() {
        let txs = makeExpenses(rubAmounts: [1_000, 1_000])
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(1_000_000),
            inputCurrency: "RUB",
            type: .income,
            allTransactions: txs,
            context: context,
            now: now
        )
        XCTAssertFalse(decision.shouldConfirm)
    }

    /// No prior transactions → no median → no opinion → no alert.
    /// Critical for first-run UX so we don't terrify the user with
    /// their first expense entry.
    func test_emptyHistory_skipsAlert() {
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(50_000),
            inputCurrency: "RUB",
            type: .expense,
            allTransactions: [],
            context: context,
            now: now
        )
        XCTAssertFalse(decision.shouldConfirm)
        XCTAssertEqual(decision.medianInBaseDisplay, 0)
    }

    /// Only income/transfer in history → median computation returns
    /// 0 → guard skips (same effective behavior as empty history,
    /// just exercising the type filter).
    func test_zeroMedian_skipsAlert() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        let incomeTx = Transaction(
            id: "tx-inc",
            userId: "u1",
            accountId: rubAccount.id,
            amount: 100_00,
            amountNative: 100_00,
            currency: "RUB",
            description: nil,
            categoryId: nil,
            type: .income,
            date: f.string(from: now),
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(50_000),
            inputCurrency: "RUB",
            type: .expense,
            allTransactions: [incomeTx],
            context: context,
            now: now
        )
        XCTAssertFalse(decision.shouldConfirm)
    }

    /// Currency without a rate in the table → can't normalize → bail
    /// out without firing. Guards against the legacy "1 IDR == 1 RUB"
    /// path that produced the original phantom-balance bug.
    func test_currencyWithoutRate_skipsAlert() {
        let txs = makeExpenses(rubAmounts: [1_000, 1_000, 1_000])
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(1_000_000),
            inputCurrency: "IDR", // not in `rates` fixture
            type: .expense,
            allTransactions: txs,
            context: context,
            now: now
        )
        XCTAssertFalse(decision.shouldConfirm)
        XCTAssertNil(decision.inputInBaseDisplay)
    }

    /// Boundary contract: input EXACTLY 5× the median is not "much
    /// bigger than usual" — strict `>`, not `>=`. Pin this so a
    /// future refactor doesn't quietly flip the comparison.
    func test_inputExactlyFiveTimesMedian_skipsAlert() {
        let txs = makeExpenses(rubAmounts: [1_000, 1_000, 1_000])
        let decision = TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: Decimal(5_000),
            inputCurrency: "RUB",
            type: .expense,
            allTransactions: txs,
            context: context,
            now: now
        )
        XCTAssertFalse(decision.shouldConfirm,
                       "Exactly 5× median must NOT fire — guard uses strict >.")
    }
}
