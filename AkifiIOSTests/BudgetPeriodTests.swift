import XCTest
@testable import AkifiIOS

/// Period windows, whole-day counts (D5), the window label (D4), rollover
/// carry (M10) and the cross-budget daily minimum in base currency (M6).
/// The same rules are asserted on the SQL side in the 20261117130003
/// dry-run (budget_period_bounds / budget_previous_period).
final class BudgetPeriodTests: XCTestCase {

    private let cal = BudgetMath.calendar

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func key(_ date: Date) -> String { AppDateFormatters.isoDate.string(from: date) }

    private func budget(
        id: String = "b1",
        amount: Int64 = 30_000_00,
        period: BillingPeriod = .monthly,
        createdAt: String? = "2026-05-06T12:00:00.000000+00:00",
        rollover: Bool = false,
        currency: String? = "RUB",
        customStart: String? = nil,
        customEnd: String? = nil
    ) -> Budget {
        Budget(id: id, userId: "u1", amount: amount, billingPeriod: period,
               customStartDate: customStart, customEndDate: customEnd,
               rolloverEnabled: rollover, currency: currency, createdAt: createdAt)
    }

    private func expense(_ id: String, _ amount: Int64, on date: String, account: String = "acc") -> Transaction {
        Transaction(id: id, userId: "u1", accountId: account, amount: amount, amountNative: amount,
                    currency: "RUB", description: nil, categoryId: nil, type: .expense, date: date,
                    merchantName: nil, merchantFuzzy: nil, transferGroupId: nil, status: nil,
                    createdAt: nil, updatedAt: nil)
    }

    private let rub: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 80], "RUB")

    // MARK: - Windows (same cases as the SQL dry run)

    func test_monthlyRollingWindow_anchoredAtCreatedAt() {
        // «Питание»: created 2026-05-06 → on 2026-11-17 the 7th window.
        let p = BudgetMath.currentPeriod(for: budget(), now: day(2026, 11, 17))
        XCTAssertEqual(key(p.start), "2026-11-02")
        XCTAssertEqual(key(p.end), "2026-12-01")
    }

    func test_weekly_mondayToSunday() {
        let tue = BudgetMath.currentPeriod(for: budget(period: .weekly), now: day(2026, 11, 17))
        let sun = BudgetMath.currentPeriod(for: budget(period: .weekly), now: day(2026, 11, 22))
        XCTAssertEqual(key(tue.start), "2026-11-16")
        XCTAssertEqual(key(tue.end), "2026-11-22")
        XCTAssertEqual(key(sun.start), "2026-11-16")
    }

    func test_quarterYearCustom() {
        let q = BudgetMath.currentPeriod(for: budget(period: .quarterly), now: day(2026, 11, 17))
        XCTAssertEqual([key(q.start), key(q.end)], ["2026-10-01", "2026-12-31"])
        let y = BudgetMath.currentPeriod(for: budget(period: .yearly), now: day(2026, 11, 17))
        XCTAssertEqual([key(y.start), key(y.end)], ["2026-01-01", "2026-12-31"])
        let c = BudgetMath.currentPeriod(for: budget(period: .custom, customStart: "2026-11-01", customEnd: "2026-11-30"), now: day(2026, 11, 17))
        XCTAssertEqual([key(c.start), key(c.end)], ["2026-11-01", "2026-11-30"])
    }

    // MARK: - D5: whole days, today inclusive

    func test_daysMeta_lastDayStillHasOneDayLeft() {
        let start = day(2026, 11, 2, hour: 0), end = day(2026, 12, 1, hour: 0)
        let last = BudgetMath.daysMeta(start: start, end: end, today: day(2026, 12, 1, hour: 23))
        XCTAssertEqual(last.total, 30)
        XCTAssertEqual(last.remaining, 1, "the last day is still spendable (was 0 → red zero)")
        XCTAssertEqual(last.elapsed, 30)

        let dayBefore = BudgetMath.daysMeta(start: start, end: end, today: day(2026, 11, 30, hour: 1))
        XCTAssertEqual(dayBefore.remaining, 2, "late-evening/early-morning rounding must not eat a day")

        let first = BudgetMath.daysMeta(start: start, end: end, today: day(2026, 11, 2, hour: 0))
        XCTAssertEqual(first.elapsed, 1)
        XCTAssertEqual(first.remaining, 30)

        let mid = BudgetMath.daysMeta(start: start, end: end, today: day(2026, 11, 17))
        XCTAssertEqual([mid.elapsed, mid.remaining], [16, 15], "same as the server for «Питание»")
    }

    func test_safeToSpend_lastDay_isTheWholeLeftover() {
        let b = budget(amount: 10_000_00)
        let lastDay = day(2026, 12, 1, hour: 20)
        let m = BudgetMath.compute(budget: b, transactions: [expense("t", 9_000_00, on: "2026-11-20")],
                                   currencyContext: rub, now: lastDay)
        XCTAssertEqual(m.remainingDays, 1)
        XCTAssertEqual(m.safeToSpendDaily, 1_000_00)
    }

    // MARK: - D4: the label is the window

    @MainActor
    func test_periodLabel_isTheWindowNotAMonthName() {
        let p = BudgetMath.currentPeriod(for: budget(), now: day(2026, 11, 17))
        let label = BudgetsViewModel.periodLabel(start: p.start, end: p.end, now: day(2026, 11, 17))
        XCTAssertTrue(label.contains("–"))
        XCTAssertTrue(label.contains("2"), label)
        XCTAssertTrue(label.contains("1"), label)
        let monthTitle = AppDateFormatters.monthYear.string(from: day(2026, 11, 17))
        XCTAssertNotEqual(label, monthTitle)
        XCTAssertFalse(label.contains("2026"), "current-year windows carry no year: \(label)")
    }

    // MARK: - M10: rollover

    func test_rollover_carriesPreviousLeftover() {
        let b = budget(amount: 10_000_00, rollover: true)
        // previous window 2026-10-03 … 2026-11-01: spent 7 000 ₽ → carry 3 000 ₽
        let txs = [expense("old", 7_000_00, on: "2026-10-20"), expense("now", 1_000_00, on: "2026-11-10")]
        let m = BudgetMath.compute(budget: b, transactions: txs, currencyContext: rub, now: day(2026, 11, 17))
        XCTAssertEqual(m.carryIn, 3_000_00)
        XCTAssertEqual(m.effectiveLimit, 13_000_00)
        XCTAssertEqual(m.spent, 1_000_00)
    }

    func test_rollover_offOrFirstWindow_noCarry() {
        let txs = [expense("old", 7_000_00, on: "2026-10-20")]
        let off = BudgetMath.compute(budget: budget(amount: 10_000_00), transactions: txs, currencyContext: rub, now: day(2026, 11, 17))
        XCTAssertEqual(off.carryIn, 0)
        let fresh = budget(amount: 10_000_00, createdAt: "2026-11-10T08:00:00Z", rollover: true)
        let first = BudgetMath.compute(budget: fresh, transactions: txs, currencyContext: rub, now: day(2026, 11, 17))
        XCTAssertEqual(first.carryIn, 0, "no previous window for a budget made this window")
        let overspent = BudgetMath.compute(budget: budget(amount: 5_000_00, rollover: true),
                                           transactions: txs, currencyContext: rub, now: day(2026, 11, 17))
        XCTAssertEqual(overspent.carryIn, 0, "an overspent month carries nothing (never negative)")
    }

    // MARK: - M6: compare allowances in the base currency

    func test_minDailySafeToSpend_convertsBeforeTakingTheMinimum() {
        let ctx: BudgetMath.CurrencyContext = ([:], ["USD": 1, "RUB": 92.5], "RUB")
        let now = day(2026, 11, 17)
        // USD budget: $100 over its remaining days → ~$6.67/day ≈ 616 ₽/day
        let usd = budget(id: "usd", amount: 100_00, period: .custom, currency: "USD",
                         customStart: "2026-11-17", customEnd: "2026-12-01")
        // RUB budget: 3 000 ₽ over the same days → 200 ₽/day — the real minimum
        let rubBudget = budget(id: "rub", amount: 3_000_00, period: .custom, currency: "RUB",
                               customStart: "2026-11-17", customEnd: "2026-12-01")
        let items = [usd, rubBudget].map { b in
            (budget: b, metrics: BudgetMath.compute(budget: b, transactions: [], currencyContext: ctx, now: now))
        }
        let daily = BudgetMath.minDailySafeToSpend(items, currencyContext: ctx)
        XCTAssertEqual(daily, 200, "the $6.67 must not win as «6,67 ₽»")
    }
}
