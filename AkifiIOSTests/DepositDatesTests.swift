import XCTest
@testable import AkifiIOS

/// D3 — deposit day strings are the user's local day.
final class DepositDatesTests: XCTestCase {

    private let utcPlus7 = TimeZone(secondsFromGMT: 7 * 3600)!

    /// 05:00 on 1 December in UTC+7 (= 22:00 UTC on 30 November).
    private var fiveAMFirstDecember: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utcPlus7
        return c.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 5))!
    }

    func test_topUpAt5amUTCPlus7_isWrittenAsFirstDecember() {
        XCTAssertEqual(DepositsViewModel.formatDate(fiveAMFirstDecember, in: utcPlus7), "2026-12-01")
        // What the old UTC formatter wrote — November's reports and budgets.
        XCTAssertEqual(DepositsViewModel.formatDate(fiveAMFirstDecember, in: TimeZone(identifier: "UTC")!), "2026-11-30")
    }

    func test_formatDate_usesTheDeviceZone() {
        let now = Date()
        XCTAssertEqual(DepositsViewModel.formatDate(now), AppDateFormatters.localDate(in: .current).string(from: now))
    }

    func test_parseAndFormat_roundTripLocalDays() {
        for s in ["2026-12-01", "2024-02-29", "2026-03-29"] {
            let d = DepositsViewModel.parseDate(s)!
            XCTAssertEqual(DepositsViewModel.formatDate(d), s)
            XCTAssertEqual(InterestCalculator.defaultCalendar.startOfDay(for: d), d, "parsed at local midnight")
        }
    }

    func test_interestCalendar_isGregorianInTheDeviceZone() {
        let cal = InterestCalculator.defaultCalendar
        XCTAssertEqual(cal.identifier, .gregorian)
        XCTAssertEqual(cal.timeZone.secondsFromGMT(for: Date()), TimeZone.current.secondsFromGMT(for: Date()))
    }

    /// A lot contributed "today" (local) accrues nothing today and one day
    /// tomorrow, whatever the hour — the UTC calendar was a day off between
    /// local midnight and the UTC rollover.
    func test_lotContributedToday_accruesFromTheLocalDay() {
        let today = Date()
        let lot = DepositContribution(
            id: "c1", depositId: "d1", userId: "u1", amount: 1_000_000_00,
            contributedAt: DepositsViewModel.formatDate(today)
        )
        XCTAssertEqual(InterestCalculator.accrueInterest(
            contributions: [lot], rate: 36.5, frequency: .simple, asOf: today
        ), 0)
        let tomorrow = InterestCalculator.defaultCalendar.date(byAdding: .day, value: 1, to: today)!
        XCTAssertGreaterThan(InterestCalculator.accrueInterest(
            contributions: [lot], rate: 36.5, frequency: .simple, asOf: tomorrow
        ), 0)
    }

    func test_closedAt_isAUTCInstant() {
        XCTAssertEqual(DepositsViewModel.formatDateTime(fiveAMFirstDecember), "2026-11-30T22:00:00Z")
    }
}
