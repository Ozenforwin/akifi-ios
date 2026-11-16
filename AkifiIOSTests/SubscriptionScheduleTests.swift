import XCTest
@testable import AkifiIOS

/// D2 — the schedule contract shared with `supabase/functions/_shared/schedule.ts`:
/// k-th charge = anchor + k periods, months added to the ANCHOR and clamped,
/// weekly +7k days, custom +30k days; next = first anchor + k·period (k ≥ 0)
/// strictly after the last charged date.
///
/// The sequences below are the cross-platform test vectors: the Deno port
/// must produce exactly the same strings.
final class SubscriptionScheduleTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func d(_ s: String) -> Date { SubscriptionDateEngine.parseDay(s, calendar: cal)! }

    private func s(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func sequence(_ anchor: String, _ period: BillingPeriod, _ ks: ClosedRange<Int>) -> [String] {
        ks.map { s(SubscriptionDateEngine.chargeDate(anchor: d(anchor), period: period, index: $0, calendar: cal)) }
    }

    private func next(after last: String, anchor: String, _ period: BillingPeriod) -> String {
        s(SubscriptionDateEngine.firstChargeDate(after: d(last), anchor: d(anchor), period: period, calendar: cal))
    }

    // MARK: - Sequences (anchor + k periods)

    func test_monthly_from31Jan_clampsEveryMonthToItsLength() {
        XCTAssertEqual(sequence("2026-01-31", .monthly, 0...12), [
            "2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30",
            "2026-07-31", "2026-08-31", "2026-09-30", "2026-10-31", "2026-11-30", "2026-12-31",
            "2027-01-31",
        ])
    }

    func test_monthly_from31Jan_leapYearFebruary() {
        XCTAssertEqual(sequence("2024-01-31", .monthly, 0...3),
                       ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30"])
    }

    func test_monthly_from30And29Jan() {
        XCTAssertEqual(sequence("2026-01-30", .monthly, 0...3),
                       ["2026-01-30", "2026-02-28", "2026-03-30", "2026-04-30"])
        XCTAssertEqual(sequence("2026-01-29", .monthly, 0...2),
                       ["2026-01-29", "2026-02-28", "2026-03-29"])
    }

    func test_monthly_ordinaryDay() {
        XCTAssertEqual(sequence("2026-11-17", .monthly, 0...2), ["2026-11-17", "2026-12-17", "2027-01-17"])
    }

    func test_monthly_negativeIndexWalksBackFromTheAnchor() {
        XCTAssertEqual(sequence("2026-03-31", .monthly, -3...0),
                       ["2025-12-31", "2026-01-31", "2026-02-28", "2026-03-31"])
    }

    func test_quarterly_from30Nov() {
        XCTAssertEqual(sequence("2025-11-30", .quarterly, 0...4),
                       ["2025-11-30", "2026-02-28", "2026-05-30", "2026-08-30", "2026-11-30"])
    }

    func test_quarterly_from31Aug() {
        XCTAssertEqual(sequence("2025-08-31", .quarterly, 0...4),
                       ["2025-08-31", "2025-11-30", "2026-02-28", "2026-05-31", "2026-08-31"])
    }

    func test_yearly_from29Feb_comesBackInLeapYears() {
        XCTAssertEqual(sequence("2024-02-29", .yearly, 0...4),
                       ["2024-02-29", "2025-02-28", "2026-02-28", "2027-02-28", "2028-02-29"])
    }

    func test_yearly_centuryRule() {
        // 2100 is not a leap year, 2000 was.
        XCTAssertEqual(sequence("2096-02-29", .yearly, 0...1), ["2096-02-29", "2097-02-28"])
        XCTAssertEqual(sequence("2096-02-29", .yearly, 4...4), ["2100-02-28"])
        XCTAssertEqual(sequence("1996-02-29", .yearly, 4...4), ["2000-02-29"])
    }

    func test_weekly_crossesMonthAndYear() {
        XCTAssertEqual(sequence("2026-12-22", .weekly, 0...3),
                       ["2026-12-22", "2026-12-29", "2027-01-05", "2027-01-12"])
    }

    func test_custom_isThirtyDays() {
        XCTAssertEqual(sequence("2026-01-31", .custom, 0...2), ["2026-01-31", "2026-03-02", "2026-04-01"])
    }

    // MARK: - next_payment_date

    func test_next_isStrictlyAfterTheLastChargedDate() {
        XCTAssertEqual(next(after: "2026-01-31", anchor: "2026-01-31", .monthly), "2026-02-28")
        XCTAssertEqual(next(after: "2026-02-28", anchor: "2026-01-31", .monthly), "2026-03-31")
        XCTAssertEqual(next(after: "2026-03-30", anchor: "2026-01-31", .monthly), "2026-03-31")
        XCTAssertEqual(next(after: "2026-03-31", anchor: "2026-01-31", .monthly), "2026-04-30")
    }

    func test_next_beforeTheAnchorIsTheAnchor() {
        XCTAssertEqual(next(after: "2025-12-01", anchor: "2026-01-31", .monthly), "2026-01-31")
        XCTAssertEqual(next(after: "2026-01-30", anchor: "2026-01-31", .monthly), "2026-01-31")
    }

    func test_next_otherPeriods() {
        XCTAssertEqual(next(after: "2026-02-28", anchor: "2025-11-30", .quarterly), "2026-05-30")
        XCTAssertEqual(next(after: "2027-02-28", anchor: "2024-02-29", .yearly), "2028-02-29")
        XCTAssertEqual(next(after: "2026-11-20", anchor: "2026-11-17", .weekly), "2026-11-24")
        XCTAssertEqual(next(after: "2026-11-24", anchor: "2026-11-17", .weekly), "2026-12-01")
        XCTAssertEqual(next(after: "2026-03-01", anchor: "2026-01-31", .custom), "2026-03-02")
    }

    /// The JS bug the contract replaces: `setUTCMonth` on 31 Jan gave 3 March
    /// and February was never charged.
    func test_next_neverSkipsFebruary() {
        XCTAssertEqual(next(after: "2026-01-31", anchor: "2026-01-31", .monthly), "2026-02-28")
    }

    // MARK: - nearest / on-schedule / previous

    func test_nearestChargeDate() {
        let a = d("2026-01-31")
        XCTAssertEqual(s(SubscriptionDateEngine.nearestChargeDate(to: d("2026-03-03"), anchor: a, period: .monthly, calendar: cal)), "2026-02-28")
        XCTAssertEqual(s(SubscriptionDateEngine.nearestChargeDate(to: d("2026-03-16"), anchor: a, period: .monthly, calendar: cal)), "2026-03-31")
        XCTAssertEqual(s(SubscriptionDateEngine.nearestChargeDate(to: d("2025-12-29"), anchor: a, period: .monthly, calendar: cal)), "2025-12-31")
        XCTAssertEqual(s(SubscriptionDateEngine.nearestChargeDate(to: d("2026-11-19"), anchor: d("2026-11-17"), period: .weekly, calendar: cal)), "2026-11-17")
    }

    func test_isOnSchedule() {
        let a = d("2026-01-31")
        XCTAssertTrue(SubscriptionDateEngine.isOnSchedule(d("2026-02-28"), anchor: a, period: .monthly, calendar: cal))
        XCTAssertTrue(SubscriptionDateEngine.isOnSchedule(d("2025-11-30"), anchor: a, period: .monthly, calendar: cal))
        XCTAssertFalse(SubscriptionDateEngine.isOnSchedule(d("2026-03-28"), anchor: a, period: .monthly, calendar: cal))
    }

    func test_previousChargeDate() {
        let a = d("2026-01-31")
        XCTAssertEqual(s(SubscriptionDateEngine.previousChargeDate(before: d("2026-03-31"), anchor: a, period: .monthly, calendar: cal)), "2026-02-28")
        XCTAssertEqual(s(SubscriptionDateEngine.previousChargeDate(before: d("2026-03-15"), anchor: a, period: .monthly, calendar: cal)), "2026-02-28")
        XCTAssertEqual(s(SubscriptionDateEngine.previousChargeDate(before: d("2026-11-24"), anchor: d("2026-11-17"), period: .weekly, calendar: cal)), "2026-11-17")
    }

    // MARK: - Stored subscriptions

    private func sub(start: String, next: String?, last: String? = nil, period: BillingPeriod = .monthly) -> SubscriptionTracker {
        SubscriptionTracker(
            id: "s1", userId: "u1", serviceName: "Netflix", amount: 999_00, currency: "RUB",
            billingPeriod: period, startDate: start, lastPaymentDate: last, nextPaymentDate: next
        )
    }

    func test_anchor_isStartDateWhenNextLiesOnItsSchedule() {
        XCTAssertEqual(s(SubscriptionDateEngine.anchor(for: sub(start: "2026-01-31", next: "2026-04-30"), calendar: cal)!), "2026-01-31")
        XCTAssertEqual(s(SubscriptionDateEngine.anchor(for: sub(start: "2026-01-31", next: nil), calendar: cal)!), "2026-01-31")
    }

    /// Prod has rows whose start_date is "added on the 1st" while billing
    /// happens on the 21st; their schedule follows next_payment_date.
    func test_anchor_legacyOffScheduleStartFallsBackToNext() {
        XCTAssertEqual(s(SubscriptionDateEngine.anchor(for: sub(start: "2026-01-01", next: "2026-01-21"), calendar: cal)!), "2026-01-21")
    }

    func test_resolveAnchor() {
        // Kept: next is on the old anchor's schedule.
        XCTAssertEqual(s(SubscriptionDateEngine.resolveAnchor(candidates: [d("2026-01-31")], nextPayment: d("2026-02-28"), period: .monthly, calendar: cal)), "2026-01-31")
        // Off-schedule next → the next date becomes the anchor.
        XCTAssertEqual(s(SubscriptionDateEngine.resolveAnchor(candidates: [d("2026-01-31")], nextPayment: d("2026-02-27"), period: .monthly, calendar: cal)), "2026-02-27")
        // First candidate missing → the second one.
        XCTAssertEqual(s(SubscriptionDateEngine.resolveAnchor(candidates: [nil, d("2026-03-01")], nextPayment: d("2026-04-01"), period: .monthly, calendar: cal)), "2026-03-01")
        // A candidate after the next date never anchors.
        XCTAssertEqual(s(SubscriptionDateEngine.resolveAnchor(candidates: [d("2026-05-01")], nextPayment: d("2026-04-01"), period: .monthly, calendar: cal)), "2026-04-01")
    }

    func test_nextAfterPayment_earlyOrLatePaymentKeepsTheBillingDay() {
        let s1 = sub(start: "2026-10-17", next: "2026-11-17")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-11-15"), calendar: cal)), "2026-12-17")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-11-17"), calendar: cal)), "2026-12-17")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-11-20"), calendar: cal)), "2026-12-17")
    }

    func test_nextAfterPayment_offSchedulePaymentGoesToTheFollowingChargeDate() {
        let s1 = sub(start: "2026-10-17", next: "2026-11-17")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-12-01"), calendar: cal)), "2026-12-17")
    }

    func test_nextAfterPayment_neverMovesBackwards() {
        // November is already charged (next = Dec 17); an old October
        // payment recorded now must not re-open November.
        let s1 = sub(start: "2026-10-17", next: "2026-12-17", last: "2026-11-17")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-10-18"), calendar: cal)), "2026-12-17")
    }

    func test_nextAfterPayment_monthEndAnchorSurvivesFebruary() {
        let s1 = sub(start: "2026-01-31", next: "2026-02-28")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-02-28"), calendar: cal)), "2026-03-31")
    }

    func test_nextAfterPayment_legacyRowFollowsNextPaymentDate() {
        let s1 = sub(start: "2026-01-01", next: "2026-01-21")
        XCTAssertEqual(s(SubscriptionDateEngine.nextPaymentDate(for: s1, afterPaymentOn: d("2026-01-22"), calendar: cal)), "2026-02-21")
    }

    func test_chargedCycle_windowIsSevenDays() {
        let s1 = sub(start: "2026-10-17", next: "2026-11-17")
        XCTAssertEqual(SubscriptionDateEngine.chargedCycle(forPaymentOn: d("2026-11-24"), subscription: s1, calendar: cal).map(s), "2026-11-17")
        XCTAssertNil(SubscriptionDateEngine.chargedCycle(forPaymentOn: d("2026-11-25"), subscription: s1, calendar: cal))
        XCTAssertEqual(SubscriptionDateEngine.chargedCycle(forPaymentOn: d("2026-11-10"), subscription: s1, calendar: cal).map(s), "2026-11-17")
    }

    func test_cycleKey_dedupesPaymentsOfTheSameCycle() {
        let s1 = sub(start: "2026-10-05", next: "2026-11-05")
        // Server charged on the 5th, the bank row is dated the 7th: same cycle.
        XCTAssertEqual(SubscriptionDateEngine.cycleKey(forPaymentOn: "2026-11-05", subscription: s1),
                       SubscriptionDateEngine.cycleKey(forPaymentOn: "2026-11-07T10:00:00+00:00", subscription: s1))
        XCTAssertEqual(SubscriptionDateEngine.cycleKey(forPaymentOn: "2026-11-20", subscription: s1), "2026-11-20")
    }

    // MARK: - Device calendar independence

    func test_scheduleIgnoresABuddhistCalendarArgument() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        let r = SubscriptionDateEngine.chargeDate(anchor: d("2026-01-31"), period: .monthly, index: 1, calendar: buddhist)
        XCTAssertEqual(s(r), "2026-02-28")
    }
}
