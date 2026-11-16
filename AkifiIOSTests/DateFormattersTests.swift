import XCTest
@testable import AkifiIOS

/// D1: parsing/writing formatters must not follow the device's calendar,
/// locale or 12/24-hour setting.
final class DateFormattersTests: XCTestCase {

    /// Region Thailand: Buddhist calendar, plus a forced 12-hour clock.
    private let thaiLocale = Locale(identifier: "th_TH@calendar=buddhist;hours=h12")
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!   // UTC+7

    /// 2026-11-17 13:05:00 in Bangkok.
    private var sample: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 17; c.hour = 13; c.minute = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = bangkok
        return cal.date(from: c)!
    }

    /// What a bare formatter does on such a phone — the bug the lint blocks.
    func test_bareFormatterOnThaiPhone_writesBuddhistYear() {
        let bare = DateFormatter() // date-formatter-ok: test reproduces the hazard
        bare.locale = thaiLocale
        bare.timeZone = bangkok
        bare.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(bare.string(from: sample), "2569-11-17")
    }

    func test_applyPOSIX_overridesThaiBuddhistTwelveHourFormatter() {
        // Start from a formatter configured exactly like the Thai device…
        let df = DateFormatter() // date-formatter-ok: test input
        df.locale = thaiLocale
        df.calendar = Calendar(identifier: .buddhist)
        df.timeZone = bangkok

        AppDateFormatters.applyPOSIX(df, format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: bangkok)

        // …gregorian year, 24-hour clock, no AM/PM marker.
        XCTAssertEqual(df.string(from: sample), "2026-11-17T13:05:00")
        XCTAssertEqual(df.calendar.identifier, .gregorian)
        XCTAssertEqual(df.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(df.date(from: "2026-11-17T13:05:00"), sample)
    }

    func test_factoryFormatters_arePinned() {
        for df in [AppDateFormatters.isoDate, AppDateFormatters.localDateTime,
                   AppDateFormatters.utcDate, AppDateFormatters.utcDateTime,
                   AppDateFormatters.utcTimestamp] {
            XCTAssertEqual(df.calendar.identifier, .gregorian, df.dateFormat)
            XCTAssertEqual(df.locale.identifier, "en_US_POSIX", df.dateFormat)
        }
        XCTAssertEqual(AppDateFormatters.utcDate.timeZone.secondsFromGMT(), 0)
        XCTAssertEqual(AppDateFormatters.posix("HH:mm", timeZone: bangkok).string(from: sample), "13:05")
    }

    func test_localDate_isTheUsersDay_notUTC() {
        // 05:00 on 1 Dec in UTC+7 is still 30 Nov in UTC.
        let fiveAM = ISO8601DateFormatter().date(from: "2026-11-30T22:00:00Z")! // date-formatter-ok: test input
        XCTAssertEqual(AppDateFormatters.localDate(in: bangkok).string(from: fiveAM), "2026-12-01")
        XCTAssertEqual(AppDateFormatters.utcDate.string(from: fiveAM), "2026-11-30")
    }

    // MARK: - day(_:calendar:)

    func test_day_parsesFirstTenCharactersAsLocalMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = bangkok
        let d = AppDateFormatters.day("2026-11-17T00:30:00+00:00", calendar: cal)
        XCTAssertEqual(d, cal.date(from: DateComponents(year: 2026, month: 11, day: 17)))
    }

    func test_day_rejectsGarbageAndImpossibleDates() {
        XCTAssertNil(AppDateFormatters.day(nil))
        XCTAssertNil(AppDateFormatters.day("2026-11"))
        XCTAssertNil(AppDateFormatters.day("2026-02-30"))
        XCTAssertNil(AppDateFormatters.day("17.11.2026"))
        XCTAssertNotNil(AppDateFormatters.day("2024-02-29"))
    }

    func test_day_buddhistCalendarArgumentIsTreatedAsGregorian() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok
        let d = AppDateFormatters.day("2026-11-17", calendar: buddhist)!
        XCTAssertEqual(AppDateFormatters.localDate(in: bangkok).string(from: d), "2026-11-17")
    }

    // MARK: - parseTimestamp

    func test_parseTimestamp_postgrestShapes() {
        let expected = ISO8601DateFormatter().date(from: "2026-11-17T00:30:00Z")! // date-formatter-ok: test input
        let shapes = [
            "2026-11-17T00:30:00+00:00",
            "2026-11-17T00:30:00Z",
            "2026-11-17T00:30:00",
            "2026-11-17 00:30:00+00",
            "2026-11-17T07:30:00+07:00",
            "2026-11-17T07:30:00+0700",
            "2026-11-16T21:30:00-03:00",
        ]
        for s in shapes {
            XCTAssertEqual(AppDateFormatters.parseTimestamp(s), expected, s)
        }
        let micro = AppDateFormatters.parseTimestamp("2026-11-17T00:30:00.123456+00:00")!
        XCTAssertEqual(micro.timeIntervalSince(expected), 0.123456, accuracy: 0.000_001)
    }

    func test_parseTimestamp_rejectsGarbage() {
        XCTAssertNil(AppDateFormatters.parseTimestamp(""))
        XCTAssertNil(AppDateFormatters.parseTimestamp("2026-11-17"))
        XCTAssertNil(AppDateFormatters.parseTimestamp("2026-11-17T00:30:00 PST"))
        XCTAssertNil(AppDateFormatters.parseTimestamp("2026-11-17T00:30:00+7"))
    }

    // MARK: - Transaction.formattedDateTime

    func test_formattedDateTime_readsCreatedAtWithTSeparator() {
        // `created_at` arrives as `…T…+00:00`; the old parser expected a
        // space and silently dropped the time.
        let createdAt = "2026-11-17T06:30:00.000000+00:00"
        let tx = Transaction(
            id: "t1", userId: "u1", accountId: "a1", amount: 100_00, currency: "RUB",
            description: nil, categoryId: nil, type: .expense, date: "2026-11-17",
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: createdAt, updatedAt: nil
        )
        let instant = AppDateFormatters.parseTimestamp(createdAt)!
        let time = AppDateFormatters.shortTime.string(from: instant)
        let day = AppDateFormatters.shortDate.string(from: AppDateFormatters.isoDate.date(from: "2026-11-17")!)
        XCTAssertEqual(tx.formattedDateTime, "\(day), \(time)")
    }
}
