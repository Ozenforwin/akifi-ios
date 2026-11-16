import XCTest
@testable import AkifiIOS

/// D7 — the auto-matcher must (a) only match a transaction within ±7 days of
/// a scheduled charge date and (b) never pay a cycle that is already paid.
final class SubscriptionMatcherWindowTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func sub(start: String = "2026-01-05", last: String?, next: String?) -> SubscriptionTracker {
        SubscriptionTracker(
            id: "railway", userId: "u1", serviceName: "Railway", amount: 500_00, currency: "RUB",
            billingPeriod: .monthly, startDate: start, lastPaymentDate: last, nextPaymentDate: next
        )
    }

    private func tx(_ date: String, amount: Int64 = 500_00) -> Transaction {
        Transaction(
            id: "tx-\(date)", userId: "u1", accountId: "a1", amount: amount, currency: "RUB",
            description: nil, categoryId: nil, type: .expense, date: date,
            merchantName: "RAILWAY APP", merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func ymd(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The finding: cron charged on the 5th (last = 5 Apr, next = 5 May),
    /// the bank row is entered on the 7th. It used to become a second
    /// payment and move the schedule to the 7th.
    func test_cycleAlreadyChargedByServer_isNotMatchedAgain() {
        let s = sub(last: "2026-04-05", next: "2026-05-05")
        XCTAssertNil(SubscriptionMatcher.bestMatch(for: tx("2026-04-07"), in: [s], calendar: cal))
    }

    func test_unpaidCycle_matchesAndKeepsTheBillingDay() {
        let s = sub(last: "2026-03-05", next: "2026-04-05")
        let match = SubscriptionMatcher.bestMatch(for: tx("2026-04-07"), in: [s], calendar: cal)
        XCTAssertNotNil(match)
        XCTAssertEqual(match.map { ymd($0.chargeDate) }, "2026-04-05")
        let next = SubscriptionDateEngine.nextPaymentDate(for: s, afterPaymentOn: SubscriptionDateEngine.parseDay("2026-04-07", calendar: cal)!, calendar: cal)
        XCTAssertEqual(ymd(next), "2026-05-05", "schedule stays on the 5th")
    }

    func test_amountAndMerchantAloneNoLongerMatchOutsideTheWindow() {
        // 70 points (amount + merchant) used to clear the 60 threshold with
        // no date agreement at all.
        let s = sub(last: "2026-03-05", next: "2026-04-05")
        let far = tx("2026-04-20")    // 15 days from 5 Apr and from 5 May
        let score = SubscriptionMatcher.score(transaction: far, subscription: s, calendar: cal)
        XCTAssertEqual(score.amount, 50)
        XCTAssertEqual(score.merchant, 20)
        XCTAssertEqual(score.total, 0)
        XCTAssertNil(SubscriptionMatcher.bestMatch(for: far, in: [s], calendar: cal))
    }

    func test_windowEdge_sevenDaysStillMatches_eightDoNot() {
        let s = sub(last: "2026-03-05", next: "2026-04-05")
        XCTAssertNotNil(SubscriptionMatcher.bestMatch(for: tx("2026-04-12"), in: [s], calendar: cal))
        XCTAssertNil(SubscriptionMatcher.bestMatch(for: tx("2026-04-13"), in: [s], calendar: cal))
        XCTAssertNotNil(SubscriptionMatcher.bestMatch(for: tx("2026-03-29"), in: [s], calendar: cal))
    }

    func test_dateScoreMeasuresAgainstTheSchedule_notOnlyNextPaymentDate() {
        // History: a March charge two days late still scores on date.
        let s = sub(last: nil, next: "2026-05-05")
        let score = SubscriptionMatcher.score(transaction: tx("2026-03-07"), subscription: s, calendar: cal)
        XCTAssertEqual(score.date, Int((30.0 * (1 - 2.0 / 7.0)).rounded()))
        XCTAssertEqual(score.total, 50 + score.date + 20)
    }

    func test_earlyPaymentForTheUpcomingCycleMatches() {
        let s = sub(last: "2026-03-05", next: "2026-04-05")
        let match = SubscriptionMatcher.bestMatch(for: tx("2026-04-03"), in: [s], calendar: cal)
        XCTAssertEqual(match.map { ymd($0.chargeDate) }, "2026-04-05")
    }

    func test_offScheduleLastPayment_blocksCyclesUpToIt() {
        // A manual payment on the 20th (off-schedule) covers everything up
        // to the 20th; the 5 April cycle is not re-matched.
        let s = sub(last: "2026-04-20", next: "2026-05-05")
        XCTAssertNil(SubscriptionMatcher.bestMatch(for: tx("2026-04-06"), in: [s], calendar: cal))
        XCTAssertNotNil(SubscriptionMatcher.bestMatch(for: tx("2026-05-06"), in: [s], calendar: cal))
    }

    func test_isAlreadyCharged() {
        let s = sub(last: "2026-04-06", next: "2026-05-05")
        let april = SubscriptionDateEngine.parseDay("2026-04-05", calendar: cal)!
        let may = SubscriptionDateEngine.parseDay("2026-05-05", calendar: cal)!
        XCTAssertTrue(SubscriptionMatcher.isAlreadyCharged(april, subscription: s, calendar: cal))
        XCTAssertFalse(SubscriptionMatcher.isAlreadyCharged(may, subscription: s, calendar: cal))
        XCTAssertFalse(SubscriptionMatcher.isAlreadyCharged(april, subscription: sub(last: nil, next: "2026-04-05"), calendar: cal))
    }
}
