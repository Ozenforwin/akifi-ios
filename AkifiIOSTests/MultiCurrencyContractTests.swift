import XCTest
@testable import AkifiIOS

/// Contract tests for ADR-001 multi-currency invariants.
///
/// These tests pin down the aggregation boundary: a transaction entered
/// in foreign currency on a differently-denominated account must be
/// FX-normalized before summation. The Phase 1 hotfix moved the four
/// user-visible aggregation sites onto `amountInBase`; these tests
/// guard that contract with hardcoded rates, so the expected kopeck
/// values are bit-exact and independent of the live FX API.
///
/// Mirror of the screenshot scenario: 76 000 ₫ on a RUB "Семейный"
/// account at rate VND→RUB ≈ 0.00365 should appear as ≈ 277 ₽ in
/// analytics, NOT 76 000 ₽ (the original bug).
final class MultiCurrencyContractTests: XCTestCase {

    // MARK: - Fixtures

    /// Hardcoded rates pinned against USD pivot (same convention as
    /// `NetWorthCalculator.convert`). Values are deliberately round so
    /// arithmetic in assertions stays transparent.
    ///
    /// Rates as of April 2026: 1 USD ≈ 92.5 RUB, 1 USD ≈ 25 400 VND,
    /// 1 USD ≈ 0.92 EUR. So 1 VND ≈ 92.5 / 25 400 ≈ 0.003642 RUB.
    private let usdPivotRates: [String: Decimal] = [
        "USD": Decimal(1.0),
        "RUB": Decimal(92.5),
        "VND": Decimal(25_400),
        "EUR": Decimal(string: "0.92")!,
        "IDR": Decimal(16_300)
    ]

    /// RUB-denominated "Семейный" account (id = acc-rub).
    private let rubAccount = Account(
        id: "acc-rub",
        userId: "u1",
        name: "Семейный",
        icon: "🏠",
        color: "#3B82F6",
        initialBalance: 100_000_00,    // 100 000 ₽
        currency: "RUB"
    )

    /// USD-denominated "ByBit" account (id = acc-usd).
    private let usdAccount = Account(
        id: "acc-usd",
        userId: "u1",
        name: "ByBit",
        icon: "💰",
        color: "#F59E0B",
        initialBalance: 500_00,        // 500 $
        currency: "USD"
    )

    private var accountsById: [String: Account] {
        [rubAccount.id: rubAccount, usdAccount.id: usdAccount]
    }

    /// Screenshot-mirror transaction: 76 000 ₫ on the RUB account.
    /// After ADR-001 write-path prebake: `amountNative = 277_00` (≈
    /// 277 RUB kopecks). `foreign_amount` captures original entry.
    private func makeVNDTaxiOnRubAccount() -> Transaction {
        // 76 000 VND × 0.003642 ≈ 276.83 RUB → 277_00 kopecks
        return Transaction(
            id: "tx-taxi-vnd",
            userId: "u1",
            accountId: rubAccount.id,
            amount: 277_00,
            amountNative: 277_00,
            currency: "RUB",
            foreignAmount: Decimal(76_000),
            foreignCurrency: "VND",
            fxRate: Decimal(string: "0.003642")!,
            description: "Такси",
            categoryId: "cat-transport",
            type: .expense,
            date: "2026-04-20",
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    /// Transaction in the account's own currency (no foreign_* fields).
    private func makeRubCafe() -> Transaction {
        Transaction(
            id: "tx-cafe-rub",
            userId: "u1",
            accountId: rubAccount.id,
            amount: 1_500_00,          // 1 500 ₽
            amountNative: 1_500_00,
            currency: "RUB",
            description: "Кафе",
            categoryId: "cat-food",
            type: .expense,
            date: "2026-04-18",
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    /// Transaction on USD account in its own currency (20 $ = 2000 cents).
    private func makeUsdCafe() -> Transaction {
        Transaction(
            id: "tx-cafe-usd",
            userId: "u1",
            accountId: usdAccount.id,
            amount: 20_00,             // 20 $ cents
            amountNative: 20_00,
            currency: "USD",
            description: "Кофе",
            categoryId: "cat-food",
            type: .expense,
            date: "2026-04-17",
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    // MARK: - TransactionMath.amountInBase

    /// VND-entered tx on RUB account: `amountNative` already in RUB,
    /// so conversion to RUB base is a no-op.
    func testAmountInBase_VNDOnRubAccount_ReturnsRubKopecks() {
        let tx = makeVNDTaxiOnRubAccount()

        let kopecks = TransactionMath.amountInBase(
            tx,
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )

        // Stored amountNative=277_00 is already in RUB kopecks.
        XCTAssertEqual(kopecks, 277_00, "VND-entered tx should read back as 277 ₽, not 76 000 ₽ (the original bug)")
    }

    /// USD tx on USD account → base=RUB. 20 $ → 20 × 92.5 = 1 850 ₽.
    func testAmountInBase_UsdOnUsdAccount_ConvertedToRub() {
        let tx = makeUsdCafe()

        let kopecks = TransactionMath.amountInBase(
            tx,
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )

        // 20_00 cents × (92.5 RUB / 1 USD) = 1_850_00 kopecks.
        XCTAssertEqual(kopecks, 1_850_00)
    }

    /// Same-currency tx (RUB on RUB) is identity.
    func testAmountInBase_SameCurrency_Identity() {
        let tx = makeRubCafe()

        let kopecks = TransactionMath.amountInBase(
            tx,
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )

        XCTAssertEqual(kopecks, 1_500_00)
    }

    // MARK: - BudgetMath.spentAmount — the main Phase 1 fix target

    /// Budget "Транспорт" on RUB account with limit 5 000 ₽.
    /// A VND-entered taxi tx on the same account must sum at its
    /// RUB equivalent (~277 ₽), NOT the nominal VND number. Pre-fix
    /// this returned 76 000_00, exploding the budget to 1 520% utilization.
    func testSpentAmount_VNDTaxiOnRubBudget_SumsInRubEquivalent() {
        let ctx: BudgetMath.CurrencyContext = (
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )
        let budget = Budget(
            id: "b-transport",
            userId: "u1",
            accountIds: [rubAccount.id],
            amount: 5_000_00,          // limit 5 000 ₽
            billingPeriod: .monthly,
            categoryIds: ["cat-transport"]
        )
        let period = (
            start: ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-30T23:59:59Z")!
        )

        let spent = BudgetMath.spentAmount(
            budget: budget,
            transactions: [makeVNDTaxiOnRubAccount()],
            period: period,
            currencyContext: ctx
        )

        XCTAssertEqual(spent, 277_00, "Budget must see the RUB equivalent (~277 ₽), not the raw VND number")
    }

    /// Budget on USD account (no accountId→ uses base) with mixed-currency
    /// transactions on different accounts: the cross-account transaction
    /// doesn't leak into a budget scoped to the USD account.
    func testSpentAmount_BudgetScopedToAccount_IgnoresOtherAccountTxs() {
        let ctx: BudgetMath.CurrencyContext = (
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )
        let budgetOnUsd = Budget(
            id: "b-usd",
            userId: "u1",
            accountIds: [usdAccount.id],
            amount: 100_00,            // 100 USD-cents ... but limit is stored in kopecks,
            billingPeriod: .monthly,
            categoryIds: ["cat-food"]
        )
        let period = (
            start: ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-30T23:59:59Z")!
        )

        // RUB cafe tx should be excluded by accountId filter.
        let spent = BudgetMath.spentAmount(
            budget: budgetOnUsd,
            transactions: [makeRubCafe(), makeUsdCafe()],
            period: period,
            currencyContext: ctx
        )

        // Only makeUsdCafe matches: 20_00 in USD cents (budget's own currency).
        XCTAssertEqual(spent, 20_00)
    }

    /// Budget without linked account → currency defaults to base (RUB).
    /// Mixed-account food transactions must be summed in RUB.
    func testSpentAmount_GlobalBudget_SumsAllMatchingInBaseCurrency() {
        let ctx: BudgetMath.CurrencyContext = (
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )
        let budget = Budget(
            id: "b-food-global",
            userId: "u1",
            accountIds: nil,
            amount: 10_000_00,
            billingPeriod: .monthly,
            categoryIds: ["cat-food"]
        )
        let period = (
            start: ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-30T23:59:59Z")!
        )

        let spent = BudgetMath.spentAmount(
            budget: budget,
            transactions: [makeRubCafe(), makeUsdCafe()],
            period: period,
            currencyContext: ctx
        )

        // 1 500 ₽ + 1 850 ₽ (USD cafe FX-converted) = 3 350_00 kopecks.
        XCTAssertEqual(spent, 3_350_00)
    }

    // MARK: - Regression: the original screenshot symptom

    /// Canonical regression test: reproduces the Vladimir's screenshot
    /// scenario. Sum of several VND-taxi transactions on a RUB account
    /// must equal ~ sum of RUB equivalents, not sum of raw VND numbers.
    ///
    /// Pre-fix: three 76 000 ₫ rides → 228 000 ₽ phantom.
    /// After fix: three rides × 277 ₽ = 831 ₽.
    func testRegression_MultipleVNDTaxiTrips_DoNotAppearAsHugeRubles() {
        let ctx: BudgetMath.CurrencyContext = (
            accountsById: accountsById,
            fxRates: usdPivotRates,
            baseCode: "RUB"
        )
        let budget = Budget(
            id: "b-transport",
            userId: "u1",
            accountIds: [rubAccount.id],
            amount: 5_000_00,
            billingPeriod: .monthly,
            categoryIds: ["cat-transport"]
        )
        let period = (
            start: ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-30T23:59:59Z")!
        )
        let threeVndTaxis = [
            makeVNDTaxiOnRubAccount(),
            withChangedId(makeVNDTaxiOnRubAccount(), to: "tx-taxi-2"),
            withChangedId(makeVNDTaxiOnRubAccount(), to: "tx-taxi-3")
        ]

        let spent = BudgetMath.spentAmount(
            budget: budget,
            transactions: threeVndTaxis,
            period: period,
            currencyContext: ctx
        )

        // The bug would produce 3 × 76_000_00 = 228_000_00. After fix:
        // 3 × 277_00 = 831_00.
        XCTAssertEqual(spent, 831_00, "Phantom 228 000 ₽ must not re-appear")
        XCTAssertLessThan(spent, 5_000_00, "Budget remains well within limit after fix")
    }

    // MARK: - Helpers

    private func withChangedId(_ tx: Transaction, to newId: String) -> Transaction {
        var copy = tx
        // Transaction.id is `let`, so we can't mutate directly; reconstruct.
        return Transaction(
            id: newId,
            userId: copy.userId,
            accountId: copy.accountId,
            amount: copy.amount,
            amountNative: copy.amountNative,
            currency: copy.currency,
            foreignAmount: copy.foreignAmount,
            foreignCurrency: copy.foreignCurrency,
            fxRate: copy.fxRate,
            description: copy.description,
            categoryId: copy.categoryId,
            type: copy.type,
            date: copy.date,
            merchantName: copy.merchantName,
            merchantFuzzy: copy.merchantFuzzy,
            transferGroupId: copy.transferGroupId,
            status: copy.status,
            createdAt: copy.createdAt,
            updatedAt: copy.updatedAt
        )
    }
}
