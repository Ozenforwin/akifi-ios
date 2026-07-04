import XCTest
@testable import AkifiIOS

/// Shared-budget fixes in `BudgetMath.spentAmount`:
///
/// 1. Category matching by NAME — on a shared budget the partner's
///    same-name category has a different id; pure id-matching silently
///    dropped their spending (mirrors `ReportsViewModel.categoryBreakdown`'s
///    by-name merge).
/// 2. Multi-account filter — spending on EVERY linked account counts,
///    not just `accountIds.first`.
final class BudgetMathSharingTests: XCTestCase {

    private var defaultContext: BudgetMath.CurrencyContext {
        ([:], [:], "RUB")
    }

    /// Current month so the tx lands inside the budget's period.
    private var todayStr: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private var period: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -15, to: Date())!
        let end = cal.date(byAdding: .day, value: 15, to: Date())!
        return (start, end)
    }

    private func makeCategory(id: String, userId: String, name: String) -> AkifiIOS.Category {
        AkifiIOS.Category(
            id: id, userId: userId, accountId: nil,
            name: name, icon: "🛒", color: "#4ADE80",
            type: .expense, isActive: true, createdAt: nil
        )
    }

    private func makeTx(
        id: String,
        userId: String = "u1",
        accountId: String = "acc-1",
        amountNative: Int64 = 1_000_00,
        categoryId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: userId, accountId: accountId,
            amount: amountNative, amountNative: amountNative, currency: "RUB",
            description: nil, categoryId: categoryId, type: .expense,
            date: todayStr, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func makeBudget(categoryIds: [String]? = nil, accountIds: [String]? = nil) -> Budget {
        Budget(
            id: "b1", userId: "u1",
            accountIds: accountIds,
            amount: 10_000_00, billingPeriod: .monthly,
            categoryIds: categoryIds
        )
    }

    // MARK: - Category matching by name

    func testSpent_PartnerSameNameCategory_CountsWhenCategoriesProvided() {
        // My «Продукты» (cat-mine) is in the budget; partner's «Продукты»
        // (cat-partner, different id) must count too.
        let categories = [
            makeCategory(id: "cat-mine", userId: "u1", name: "Продукты"),
            makeCategory(id: "cat-partner", userId: "u2", name: "Продукты")
        ]
        let budget = makeBudget(categoryIds: ["cat-mine"])
        let txs = [
            makeTx(id: "t1", categoryId: "cat-mine"),
            makeTx(id: "t2", userId: "u2", categoryId: "cat-partner")
        ]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            categories: categories, currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 2_000_00, "partner's same-name category must count into the shared budget")
    }

    func testSpent_NameMatchIsCaseAndWhitespaceInsensitive() {
        let categories = [
            makeCategory(id: "cat-mine", userId: "u1", name: "Продукты"),
            makeCategory(id: "cat-partner", userId: "u2", name: " продукты ")
        ]
        let budget = makeBudget(categoryIds: ["cat-mine"])
        let txs = [makeTx(id: "t1", userId: "u2", categoryId: "cat-partner")]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            categories: categories, currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 1_000_00)
    }

    func testSpent_DifferentNameCategory_DoesNotCount() {
        let categories = [
            makeCategory(id: "cat-mine", userId: "u1", name: "Продукты"),
            makeCategory(id: "cat-other", userId: "u2", name: "Транспорт")
        ]
        let budget = makeBudget(categoryIds: ["cat-mine"])
        let txs = [makeTx(id: "t1", userId: "u2", categoryId: "cat-other")]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            categories: categories, currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 0)
    }

    func testSpent_WithoutCategoriesList_LegacyIdOnlyBehavior() {
        // No categories passed (legacy call sites / tests): id-matching only.
        let budget = makeBudget(categoryIds: ["cat-mine"])
        let txs = [
            makeTx(id: "t1", categoryId: "cat-mine"),
            makeTx(id: "t2", userId: "u2", categoryId: "cat-partner")
        ]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 1_000_00, "without a categories list only exact ids match (legacy)")
    }

    func testSpent_NoCategoryFilter_CountsEverything() {
        let budget = makeBudget(categoryIds: nil)
        let txs = [
            makeTx(id: "t1", categoryId: "any"),
            makeTx(id: "t2", categoryId: nil)
        ]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 2_000_00)
    }

    // MARK: - Multi-account filter

    func testSpent_SecondLinkedAccount_Counts() {
        // Regression: only accountIds.first used to be checked.
        let budget = makeBudget(accountIds: ["acc-1", "acc-2"])
        let txs = [
            makeTx(id: "t1", accountId: "acc-1"),
            makeTx(id: "t2", accountId: "acc-2"),
            makeTx(id: "t3", accountId: "acc-3")
        ]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 2_000_00, "both linked accounts count; unlinked acc-3 does not")
    }

    func testSpent_EmptyAccountIds_CountsAllAccounts() {
        let budget = makeBudget(accountIds: [])
        let txs = [
            makeTx(id: "t1", accountId: "acc-1"),
            makeTx(id: "t2", accountId: "acc-2")
        ]

        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period,
            currencyContext: defaultContext
        )

        XCTAssertEqual(spent, 2_000_00, "empty accountIds = no account filter")
    }

    // MARK: - External spend (partner rows via RPC)

    private func makeExternalRow(amount: Decimal, currency: String = "RUB", daysAgo: Int = 0) -> BudgetMath.ExternalSpendRow {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return BudgetMath.ExternalSpendRow(
            amountNative: amount,
            currency: currency,
            txDate: df.string(from: date)
        )
    }

    func testExternalSpent_rowInPeriod_addsToSpent() {
        let budget = makeBudget()
        let rows = [makeExternalRow(amount: 500)]

        let external = BudgetMath.externalSpent(
            rows: rows, budget: budget, period: period, currencyContext: defaultContext
        )

        XCTAssertEqual(external, 500_00, "partner's 500 ₽ lands in kopecks")
    }

    func testExternalSpent_rowOutsidePeriod_ignored() {
        let budget = makeBudget()
        let rows = [makeExternalRow(amount: 500, daysAgo: 60)]

        let external = BudgetMath.externalSpent(
            rows: rows, budget: budget, period: period, currencyContext: defaultContext
        )

        XCTAssertEqual(external, 0, "row older than the current period must not count")
    }

    func testExternalSpent_lowercaseCurrency_normalized() {
        // Legacy rows carry lowercase currency codes ('rub') — FX lookup
        // must still work.
        let budget = makeBudget()
        let rows = [makeExternalRow(amount: 300, currency: "rub")]

        let external = BudgetMath.externalSpent(
            rows: rows, budget: budget, period: period, currencyContext: defaultContext
        )

        XCTAssertEqual(external, 300_00)
    }

    func testCompute_externalRowsIncreaseUtilization() {
        // 10 000 ₽ budget: my 1 000 ₽ + partner's invisible 4 000 ₽ → 50%.
        let budget = makeBudget()
        let myTx = [makeTx(id: "t1", amountNative: 1_000_00)]
        let partnerRows = [makeExternalRow(amount: 4_000)]

        let metrics = BudgetMath.compute(
            budget: budget,
            transactions: myTx,
            externalSpendRows: partnerRows,
            currencyContext: defaultContext
        )

        XCTAssertEqual(metrics.spent, 5_000_00, "progress = my local spend + partner's external spend")
        XCTAssertEqual(metrics.utilization, 50)
    }

    // MARK: - subscriptionCommitted name matching

    func testSubscriptionCommitted_PartnerSameNameCategory_Counts() {
        let categories = [
            makeCategory(id: "cat-mine", userId: "u1", name: "Подписки"),
            makeCategory(id: "cat-partner", userId: "u2", name: "Подписки")
        ]
        let budget = makeBudget(categoryIds: ["cat-mine"])
        let sub = SubscriptionTracker(
            id: "s1", userId: "u2", serviceName: "Netflix",
            amount: 1_000_00, currency: "RUB", billingPeriod: .monthly,
            startDate: "2026-01-01", lastPaymentDate: nil, nextPaymentDate: "2026-08-01",
            categoryId: "cat-partner", reminderDays: 1, iconColor: "#60A5FA",
            isActive: true, status: .active
        )

        let committed = BudgetMath.subscriptionCommitted(
            budget: budget, subscriptions: [sub],
            categories: categories, currencyContext: defaultContext
        )

        XCTAssertEqual(committed, 1_000_00)
    }
}
