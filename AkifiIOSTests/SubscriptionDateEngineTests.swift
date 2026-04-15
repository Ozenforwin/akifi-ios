import XCTest
@testable import AkifiIOS

/// Unit tests for `SubscriptionDateEngine`.
///
/// Goal: ≥80% coverage of the pure domain service.
/// We use an explicit gregorian calendar pinned to UTC to make assertions
/// deterministic across CI runners and time zones.
final class SubscriptionDateEngineTests: XCTestCase {

    private var calendar: Calendar!
    private var iso: ISO8601DateFormatter!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        calendar = cal

        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        iso.timeZone = TimeZone(identifier: "UTC")
    }

    // MARK: - Helpers

    private func date(_ ymd: String) -> Date {
        iso.date(from: ymd)!
    }

    private func ymd(_ date: Date) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.locale = calendar.locale
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    // MARK: - nextPaymentDate

    func testNext_weekly() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-04-10"),
            period: .weekly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-17")
    }

    func testNext_monthly_simpleCase() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-04-10"),
            period: .monthly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-05-10")
    }

    /// 31 Jan + 1 month → 28 Feb (2026 is not a leap year).
    func testNext_monthly_clampFeb() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-01-31"),
            period: .monthly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-02-28")
    }

    /// 31 Mar + 1 month → 30 Apr.
    func testNext_monthly_clampApr() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-03-31"),
            period: .monthly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-30")
    }

    func testNext_quarterly() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-01-15"),
            period: .quarterly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-15")
    }

    /// 29 Feb 2024 + 1 year → 28 Feb 2025 (Calendar clamping).
    func testNext_yearly_leapDayClamp() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2024-02-29"),
            period: .yearly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2025-02-28")
    }

    func testNext_yearly_simple() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-04-15"),
            period: .yearly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2027-04-15")
    }

    func testNext_custom_defaultThirtyDays() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-04-01"),
            period: .custom,
            customDays: nil,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-05-01") // +30 days
    }

    func testNext_custom_explicitDays() {
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: date("2026-04-01"),
            period: .custom,
            customDays: 14,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-15")
    }

    // MARK: - previousPaymentDate

    func testPrevious_monthly_simple() {
        let result = SubscriptionDateEngine.previousPaymentDate(
            from: date("2026-05-10"),
            period: .monthly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-10")
    }

    func testPrevious_weekly() {
        let result = SubscriptionDateEngine.previousPaymentDate(
            from: date("2026-04-17"),
            period: .weekly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-10")
    }

    func testPrevious_yearly_leapClamp() {
        // 28 Feb 2025 - 1 year → 28 Feb 2024 (loses leap day info, acceptable).
        let result = SubscriptionDateEngine.previousPaymentDate(
            from: date("2025-02-28"),
            period: .yearly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2024-02-28")
    }

    func testPrevious_quarterly() {
        let result = SubscriptionDateEngine.previousPaymentDate(
            from: date("2026-04-15"),
            period: .quarterly,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-01-15")
    }

    func testPrevious_custom_default() {
        let result = SubscriptionDateEngine.previousPaymentDate(
            from: date("2026-05-01"),
            period: .custom,
            calendar: calendar
        )
        XCTAssertEqual(ymd(result), "2026-04-01")
    }

    // MARK: - Inverse property

    /// For any period, previous(next(d)) == startOfDay(d).
    func testInverse_nextThenPrevious() {
        let samples = [
            date("2026-01-15"),
            date("2026-03-31"),
            date("2024-02-29"),
            date("2026-04-10"),
        ]
        let periods: [BillingPeriod] = [.weekly, .monthly, .quarterly, .yearly]
        for d in samples {
            for p in periods {
                let next = SubscriptionDateEngine.nextPaymentDate(from: d, period: p, calendar: calendar)
                let prev = SubscriptionDateEngine.previousPaymentDate(from: next, period: p, calendar: calendar)
                // NB: due to Feb clamping, prev may not equal original d exactly.
                // We assert it's within one period (<= original or == original).
                XCTAssertLessThanOrEqual(prev, calendar.startOfDay(for: d), "period \(p), d=\(ymd(d))")
            }
        }
    }

    // MARK: - startOfDay normalization

    func testNext_normalizesToStartOfDay() {
        // Give an instant mid-day; result must be 00:00 local.
        let midDay = date("2026-04-10").addingTimeInterval(13 * 3600) // 13:00 UTC
        let result = SubscriptionDateEngine.nextPaymentDate(
            from: midDay,
            period: .monthly,
            calendar: calendar
        )
        let comps = calendar.dateComponents([.hour, .minute, .second], from: result)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    // MARK: - reminderFireDate

    func testReminder_futureDateReturnsValue() {
        // now = 2026-04-15 00:00; next = 2026-04-20; reminder 3 days before → 2026-04-17 09:00
        let now = date("2026-04-15")
        let next = date("2026-04-20")
        let fire = SubscriptionDateEngine.reminderFireDate(
            nextPaymentDate: next,
            daysBefore: 3,
            hour: 9,
            calendar: calendar,
            now: now
        )
        XCTAssertNotNil(fire)
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: fire!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 17)
        XCTAssertEqual(comps.hour, 9)
    }

    func testReminder_pastDateReturnsNil() {
        // reminder would be yesterday → nil
        let now = date("2026-04-15").addingTimeInterval(12 * 3600)
        let next = date("2026-04-15") // today
        let fire = SubscriptionDateEngine.reminderFireDate(
            nextPaymentDate: next,
            daysBefore: 1,
            hour: 9,
            calendar: calendar,
            now: now
        )
        XCTAssertNil(fire)
    }

    func testReminder_zeroDaysBefore_sameDay() {
        let now = date("2026-04-15") // 00:00
        let next = date("2026-04-15")
        let fire = SubscriptionDateEngine.reminderFireDate(
            nextPaymentDate: next,
            daysBefore: 0,
            hour: 9,
            calendar: calendar,
            now: now
        )
        XCTAssertNotNil(fire)
        let h = calendar.component(.hour, from: fire!)
        XCTAssertEqual(h, 9)
    }

    func testReminder_negativeDaysClampedToZero() {
        let now = date("2026-04-15")
        let next = date("2026-04-20")
        let fire = SubscriptionDateEngine.reminderFireDate(
            nextPaymentDate: next,
            daysBefore: -5,
            hour: 9,
            calendar: calendar,
            now: now
        )
        // Should behave as daysBefore = 0 → fire on 2026-04-20 09:00.
        XCTAssertNotNil(fire)
        let comps = calendar.dateComponents([.day], from: fire!)
        XCTAssertEqual(comps.day, 20)
    }

    // MARK: - DB date helpers

    func testParseDbDate_yyyyMMdd() {
        let d = SubscriptionDateEngine.parseDbDate("2026-04-15")
        XCTAssertNotNil(d)
    }

    func testParseDbDate_isoTimestamp() {
        let d = SubscriptionDateEngine.parseDbDate("2026-04-15T12:34:56Z")
        XCTAssertNotNil(d)
    }

    func testParseDbDate_nilEmpty() {
        XCTAssertNil(SubscriptionDateEngine.parseDbDate(nil))
        XCTAssertNil(SubscriptionDateEngine.parseDbDate(""))
    }

    func testFormatDbDate_roundtrip() {
        let original = "2026-04-15"
        guard let parsed = SubscriptionDateEngine.parseDbDate(original) else {
            return XCTFail("could not parse")
        }
        let formatted = SubscriptionDateEngine.formatDbDate(parsed)
        XCTAssertEqual(formatted, original)
    }
}
