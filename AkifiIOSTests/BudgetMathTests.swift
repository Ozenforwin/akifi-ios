import XCTest
@testable import AkifiIOS

/// Unit tests for `BudgetMath`, focused on the new subscription-aware logic.
///
/// Coverage:
/// - `subscriptionCommitted()` with category filtering and period normalization
/// - `normalizedAmount()` between all billing periods
/// - `compute()` end-to-end with subscription commitment
final class BudgetMathTests: XCTestCase {

    // MARK: - Factories

    /// Empty currency context — single-currency scenarios (no FX needed).
    /// `baseCode: "RUB"` means all amounts are read as-is (amountNative in
    /// RUB kopecks) without any conversion. Use this for tests that don't
    /// exercise multi-currency math.
    private var defaultContext: BudgetMath.CurrencyContext {
        ([:], [:], "RUB")
    }

    private func makeBudget(
        id: String = "b1",
        amount: Int64 = 10_000_00,
        period: BillingPeriod = .monthly,
        categoryIds: [String]? = nil
    ) -> Budget {
        Budget(
            id: id,
            userId: "u1",
            amount: amount,
            billingPeriod: period,
            categoryIds: categoryIds
        )
    }

    private func makeSub(
        id: String = "s1",
        amount: Int64 = 1_000_00,
        period: BillingPeriod = .monthly,
        categoryId: String? = nil,
        status: SubscriptionTrackerStatus = .active
    ) -> SubscriptionTracker {
        SubscriptionTracker(
            id: id,
            userId: "u1",
            serviceName: "Test",
            amount: amount,
            currency: "RUB",
            billingPeriod: period,
            startDate: "2026-01-01",
            lastPaymentDate: nil,
            nextPaymentDate: "2026-05-01",
            categoryId: categoryId,
            reminderDays: 1,
            iconColor: "#60A5FA",
            isActive: status == .active,
            status: status
        )
    }

    // MARK: - normalizedAmount

    func testNormalizedAmount_SameToSame_ReturnsUnchanged() {
        XCTAssertEqual(BudgetMath.normalizedAmount(1_000_00, from: .monthly, to: .monthly), 1_000_00)
        XCTAssertEqual(BudgetMath.normalizedAmount(1_000_00, from: .weekly, to: .weekly), 1_000_00)
    }

    func testNormalizedAmount_WeeklyToMonthly_MultipliesByFourAndThird() {
        // 100 weekly → ~433 monthly (52/12 = 4.333)
        let result = BudgetMath.normalizedAmount(100_00, from: .weekly, to: .monthly)
        XCTAssertEqual(result, 43333)
    }

    func testNormalizedAmount_MonthlyToYearly_MultipliesBy12() {
        XCTAssertEqual(BudgetMath.normalizedAmount(1_000_00, from: .monthly, to: .yearly), 12_000_00)
    }

    func testNormalizedAmount_YearlyToMonthly_DividesBy12() {
        XCTAssertEqual(BudgetMath.normalizedAmount(12_000_00, from: .yearly, to: .monthly), 1_000_00)
    }

    func testNormalizedAmount_QuarterlyToMonthly_DividesByThree() {
        XCTAssertEqual(BudgetMath.normalizedAmount(3_000_00, from: .quarterly, to: .monthly), 1_000_00)
    }

    func testNormalizedAmount_MonthlyToWeekly_RoughlyQuarter() {
        // 100 monthly → ~23 weekly (12/52 = 0.23)
        let result = BudgetMath.normalizedAmount(100_00, from: .monthly, to: .weekly)
        XCTAssertEqual(result, 2307)
    }

    // MARK: - subscriptionCommitted — empty cases

    func testSubscriptionCommitted_NoSubscriptions_ReturnsZero() {
        let budget = makeBudget()
        XCTAssertEqual(BudgetMath.subscriptionCommitted(budget: budget, subscriptions: [], currencyContext: defaultContext), 0)
    }

    func testSubscriptionCommitted_AllPaused_ReturnsZero() {
        let budget = makeBudget()
        let subs = [
            makeSub(status: .paused),
            makeSub(id: "s2", status: .cancelled)
        ]
        XCTAssertEqual(BudgetMath.subscriptionCommitted(budget: budget, subscriptions: subs, currencyContext: defaultContext), 0)
    }

    // MARK: - subscriptionCommitted — summation

    func testSubscriptionCommitted_MonthlyBudgetMonthlySubs_SumsExactly() {
        let budget = makeBudget(period: .monthly)
        let subs = [
            makeSub(amount: 500_00, period: .monthly),
            makeSub(id: "s2", amount: 300_00, period: .monthly)
        ]
        XCTAssertEqual(BudgetMath.subscriptionCommitted(budget: budget, subscriptions: subs, currencyContext: defaultContext), 800_00)
    }

    func testSubscriptionCommitted_MonthlyBudgetMixedPeriods_NormalizesToMonthly() {
        let budget = makeBudget(period: .monthly)
        let subs = [
            makeSub(amount: 1_200_00, period: .yearly),   // → 100/month
            makeSub(id: "s2", amount: 300_00, period: .quarterly), // → 100/month
            makeSub(id: "s3", amount: 200_00, period: .monthly)   // → 200/month
        ]
        // Expect ~400/month total
        let result = BudgetMath.subscriptionCommitted(budget: budget, subscriptions: subs, currencyContext: defaultContext)
        XCTAssertEqual(result, 400_00)
    }

    // MARK: - subscriptionCommitted — category filtering

    func testSubscriptionCommitted_BudgetWithCategories_FiltersByMatchingCategory() {
        let budget = makeBudget(categoryIds: ["cat-entertainment"])
        let subs = [
            makeSub(id: "s1", amount: 500_00, categoryId: "cat-entertainment"),  // match
            makeSub(id: "s2", amount: 300_00, categoryId: "cat-utilities"),      // no match
            makeSub(id: "s3", amount: 200_00, categoryId: nil)                   // no category
        ]
        XCTAssertEqual(BudgetMath.subscriptionCommitted(budget: budget, subscriptions: subs, currencyContext: defaultContext), 500_00)
    }

    func testSubscriptionCommitted_BudgetWithoutCategories_IncludesAllSubs() {
        let budget = makeBudget(categoryIds: nil)
        let subs = [
            makeSub(id: "s1", amount: 500_00, categoryId: "cat-a"),
            makeSub(id: "s2", amount: 300_00, categoryId: "cat-b"),
            makeSub(id: "s3", amount: 200_00, categoryId: nil)
        ]
        XCTAssertEqual(BudgetMath.subscriptionCommitted(budget: budget, subscriptions: subs, currencyContext: defaultContext), 1_000_00)
    }

    func testSubscriptionCommitted_EmptyCategoryArray_TreatedAsNoFilter() {
        let budget = makeBudget(categoryIds: [])
        let subs = [
            makeSub(id: "s1", amount: 500_00, categoryId: "cat-a"),
            makeSub(id: "s2", amount: 300_00, categoryId: nil)
        ]
        XCTAssertEqual(BudgetMath.subscriptionCommitted(budget: budget, subscriptions: subs, currencyContext: defaultContext), 800_00)
    }

    // MARK: - compute — end to end

    func testCompute_WithSubscriptions_FieldsPopulated() {
        let budget = makeBudget(amount: 10_000_00, period: .monthly)
        let subs = [makeSub(amount: 2_000_00, period: .monthly)]
        let metrics = BudgetMath.compute(
            budget: budget, transactions: [], subscriptions: subs,
            currencyContext: defaultContext
        )

        XCTAssertEqual(metrics.subscriptionCommitted, 2_000_00)
        XCTAssertEqual(metrics.freeRemaining, 8_000_00)  // limit - subCommitted, since spent=0
    }

    func testCompute_WithoutSubscriptions_CommittedZero() {
        let budget = makeBudget()
        let metrics = BudgetMath.compute(budget: budget, transactions: [], currencyContext: defaultContext)
        XCTAssertEqual(metrics.subscriptionCommitted, 0)
        XCTAssertEqual(metrics.freeRemaining, metrics.remaining)
    }

    func testCompute_SubsExceedLimit_FreeRemainingClampedToZero() {
        let budget = makeBudget(amount: 1_000_00)
        let subs = [makeSub(amount: 2_000_00)]
        let metrics = BudgetMath.compute(
            budget: budget, transactions: [], subscriptions: subs,
            currencyContext: defaultContext
        )

        XCTAssertEqual(metrics.subscriptionCommitted, 2_000_00)
        XCTAssertEqual(metrics.freeRemaining, 0)
    }

    func testCompute_CategoryFiltering_OnlyMatchingSubsCounted() {
        let budget = makeBudget(amount: 10_000_00, categoryIds: ["cat-1"])
        let subs = [
            makeSub(id: "s1", amount: 500_00, categoryId: "cat-1"),
            makeSub(id: "s2", amount: 500_00, categoryId: "cat-2")
        ]
        let metrics = BudgetMath.compute(
            budget: budget, transactions: [], subscriptions: subs,
            currencyContext: defaultContext
        )
        XCTAssertEqual(metrics.subscriptionCommitted, 500_00)
    }

    // MARK: - amountInBase (cross-currency aggregation)

    func testAmountInBase_ExplicitCurrencyConvertsToBase() {
        // USD-pivot rates: 80 RUB and 25 000 VND per dollar.
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 80, "VND": 25_000], "RUB")

        var vndBudget = makeBudget(amount: 4_000_000_00)
        vndBudget.currency = "VND"
        // 4 000 000 VND / 25 000 * 80 = 12 800 RUB.
        XCTAssertEqual(
            BudgetMath.amountInBase(4_000_000_00, budget: vndBudget, currencyContext: ctx),
            12_800_00
        )
    }

    func testAmountInBase_LegacyNilCurrencyIsAlreadyBase() {
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 80], "RUB")
        let legacy = makeBudget(amount: 40_000_00)
        XCTAssertEqual(
            BudgetMath.amountInBase(40_000_00, budget: legacy, currencyContext: ctx),
            40_000_00
        )
    }

    /// The «Всего бюджетов» header sums per-budget metrics that are each
    /// denominated in their own currency. Fixture mirrors the real list:
    /// two VND budgets on a VND account plus a USD one, base RUB.
    func testHeaderTotal_MixedCurrencyBudgets_SumInBaseNotRaw() {
        // 1 USD = 83.7 RUB = 26 170 VND.
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 83.7, "VND": 26_170], "RUB")

        var bike = makeBudget(id: "bike", amount: 3_000_000_00)
        bike.currency = "VND"
        var sport = makeBudget(id: "sport", amount: 4_000_000_00)
        sport.currency = "VND"
        var food = makeBudget(id: "food", amount: 400_00)
        food.currency = "USD"

        let totalInBase = [bike, sport, food].reduce(Int64(0)) { acc, budget in
            acc + BudgetMath.amountInBase(budget.amount, budget: budget, currencyContext: ctx)
        }

        // 7 000 000 ₫ ≈ 22 388 ₽ + 400 $ = 33 480 ₽ → ≈ 55 868 ₽.
        XCTAssertEqual(Double(totalInBase), 55_868_00, accuracy: 100_00)
        // The bug rendered 7 040 000 ₽ (≈84 100 $) by adding ₫ to ₽ as-is.
        XCTAssertLessThan(totalInBase, 1_000_000_00,
                          "VND limits were summed as roubles — the header explodes")
    }

    // MARK: - activeSubscriptionsMonthlyTotalInBase

    func testActiveSubscriptionsMonthlyTotal_SumsOnlyActive() {
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 83.7], "RUB")
        let subs = [
            makeSub(id: "s1", amount: 200_00, status: .active),
            makeSub(id: "s2", amount: 1_000_00, status: .paused),
            makeSub(id: "s3", amount: 500_00, status: .cancelled)
        ]

        XCTAssertEqual(
            BudgetMath.activeSubscriptionsMonthlyTotalInBase(subscriptions: subs, currencyContext: ctx),
            200_00
        )
    }

    /// Real list shape: five USD trackers totalling $255/mo, read on a
    /// RUB base — the total must be roubles, not a raw dollar sum.
    func testActiveSubscriptionsMonthlyTotal_FXNormalizesForeignCurrency() {
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 83.7], "RUB")
        let usd = [10_00, 200_00, 9_00, 25_00, 11_00].enumerated().map { index, amount in
            SubscriptionTracker(
                id: "s\(index)", userId: "u1", serviceName: "svc\(index)",
                amount: Int64(amount), currency: "USD", billingPeriod: .monthly,
                startDate: "2026-01-01"
            )
        }

        let total = BudgetMath.activeSubscriptionsMonthlyTotalInBase(subscriptions: usd, currencyContext: ctx)

        // $255 × 83.7 ≈ 21 343 ₽.
        XCTAssertEqual(Double(total), 21_343_00, accuracy: 50_00)
    }

    /// Weekly and yearly trackers are billed on their own cadence — the
    /// header advertises a MONTHLY figure.
    func testActiveSubscriptionsMonthlyTotal_NormalizesBillingPeriods() {
        let ctx: BudgetMath.CurrencyContext = ([:], [:], "RUB")
        let subs = [
            makeSub(id: "yearly", amount: 12_000_00, period: .yearly),
            makeSub(id: "quarterly", amount: 3_000_00, period: .quarterly),
            makeSub(id: "monthly", amount: 500_00, period: .monthly)
        ]

        // 1 000 + 1 000 + 500.
        XCTAssertEqual(
            BudgetMath.activeSubscriptionsMonthlyTotalInBase(subscriptions: subs, currencyContext: ctx),
            2_500_00
        )
    }

    func testAmountInBase_MissingRateFailsSafeUnchanged() {
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 80], "RUB")
        var chfBudget = makeBudget()
        chfBudget.currency = "CHF"
        XCTAssertEqual(
            BudgetMath.amountInBase(1_000_00, budget: chfBudget, currencyContext: ctx),
            1_000_00
        )
    }
}
