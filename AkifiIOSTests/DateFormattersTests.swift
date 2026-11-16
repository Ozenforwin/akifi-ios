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

/// D1 regression: every helper that stores, sends or parses a date, run with
/// a Thai phone's settings — `th_TH`, Buddhist calendar, 12-hour clock.
///
/// A plain round-trip is not enough: a bare Thai formatter turns
/// "2026-11-17" into the year 1483 and back into "2026-11-17" without
/// complaint. Each assertion therefore pins the INSTANT against a gregorian
/// reference as well as the string. Helpers that take a `calendar` get the
/// Buddhist one and must agree with the gregorian result. (Also run the whole
/// suite with `xcodebuild test -testRegion TH -testLanguage th` to put the
/// process itself on a Thai locale.)
@MainActor
final class DateFormattersThaiDeviceTests: XCTestCase {

    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!   // UTC+7

    /// Region Thailand with a 12-hour clock.
    private let thaiLocale: Locale = {
        var comps = Locale.Components(locale: Locale(identifier: "th_TH"))
        comps.calendar = .buddhist
        comps.hourCycle = .oneToTwelve
        return Locale(components: comps)
    }()

    private var buddhist: Calendar {
        var c = Calendar(identifier: .buddhist)
        c.locale = thaiLocale
        c.timeZone = bangkok
        return c
    }

    private func gregorian(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func instant(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in tz: TimeZone) -> Date {
        gregorian(tz).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 2026-11-17 13:05 in Bangkok = 06:05Z.
    private var sample: Date { instant(2026, 11, 17, 13, 5, in: bangkok) }

    // MARK: - The hazard is real

    func test_thaiDeviceFormatter_isWrong_soTheAssertionsBelowMeanSomething() {
        let device = DateFormatter() // date-formatter-ok: test reproduces the hazard
        device.locale = thaiLocale
        device.calendar = buddhist
        device.timeZone = bangkok
        device.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(device.string(from: sample), "2569-11-17")
        let misread = device.date(from: "2026-11-17")!
        XCTAssertEqual(gregorian(bangkok).component(.year, from: misread), 1483)
        // …and it round-trips anyway, which is why a string check alone proves nothing.
        XCTAssertEqual(device.string(from: misread), "2026-11-17")
    }

    // MARK: - Local day / wall-clock strings (device time zone)

    func test_localDayStrings_roundTripAsGregorian() {
        let localMidnight = instant(2026, 11, 17, in: .current)

        XCTAssertEqual(AppDateFormatters.isoDate.date(from: "2026-11-17"), localMidnight)
        XCTAssertEqual(AppDateFormatters.isoDate.string(from: localMidnight), "2026-11-17")
        XCTAssertEqual(Date.fromISO("2026-11-17"), localMidnight)
        XCTAssertEqual(localMidnight.isoDateString, "2026-11-17")

        let wall = instant(2026, 11, 17, 13, 5, in: .current)
        XCTAssertEqual(AppDateFormatters.localDateTime.string(from: wall), "2026-11-17T13:05:00")
        XCTAssertEqual(AppDateFormatters.localDateTime.date(from: "2026-11-17T13:05:00"), wall)
    }

    func test_explicitZoneHelpers_roundTripInBangkok() {
        let midnight = instant(2026, 11, 17, in: bangkok)
        XCTAssertEqual(AppDateFormatters.localDate(in: bangkok).string(from: sample), "2026-11-17")
        XCTAssertEqual(AppDateFormatters.localDate(in: bangkok).date(from: "2026-11-17"), midnight)

        let wallClock = AppDateFormatters.posix("yyyy-MM-dd'T'HH:mm:ss", timeZone: bangkok)
        XCTAssertEqual(wallClock.string(from: sample), "2026-11-17T13:05:00")   // 24h, no AM/PM
        XCTAssertEqual(wallClock.date(from: "2026-11-17T13:05:00"), sample)
        XCTAssertEqual(AppDateFormatters.posix("HH:mm", timeZone: bangkok).string(from: sample), "13:05")
    }

    func test_day_withBuddhistCalendar_isTheGregorianDay() {
        let d = AppDateFormatters.day("2026-11-17T13:05:00+00:00", calendar: buddhist)
        XCTAssertEqual(d, instant(2026, 11, 17, in: bangkok))
        XCTAssertEqual(d.map { AppDateFormatters.localDate(in: bangkok).string(from: $0) }, "2026-11-17")
    }

    // MARK: - Instants and UTC strings

    func test_utcStringsAndInstants_roundTrip() {
        let utcMidnight = instant(2026, 11, 17, in: AppDateFormatters.utcTimeZone)

        XCTAssertEqual(AppDateFormatters.utcDate.string(from: sample), "2026-11-17")
        XCTAssertEqual(AppDateFormatters.utcDate.date(from: "2026-11-17"), utcMidnight)
        XCTAssertEqual(AppDateFormatters.utcMonth.string(from: sample), "2026-11")
        XCTAssertEqual(AppDateFormatters.utcMonth.date(from: "2026-11"), instant(2026, 11, 1, in: AppDateFormatters.utcTimeZone))
        XCTAssertEqual(AppDateFormatters.utcDateTime.string(from: sample), "2026-11-17T06:05:00")
        XCTAssertEqual(AppDateFormatters.utcTimestamp.string(from: sample), "2026-11-17T06:05:00Z")
        XCTAssertEqual(AppDateFormatters.nowTimestamp(sample), "2026-11-17T06:05:00Z")
        XCTAssertEqual(AppDateFormatters.parseTimestamp("2026-11-17T06:05:00Z"), sample)
        XCTAssertEqual(AppDateFormatters.parseTimestamp(AppDateFormatters.nowTimestamp(sample)), sample)

        let iso = AppDateFormatters.iso8601([.withInternetDateTime, .withFractionalSeconds])
        XCTAssertEqual(iso.date(from: "2026-11-17T06:05:00.000+00:00"), sample)
        XCTAssertEqual(ISO8601DateFormatter.shared.date(from: "2026-11-17T06:05:00.000Z"), sample)
    }

    func test_appParsers_readServerTimestampsAsGregorian() {
        let server = "2026-11-17T06:05:00.123456+00:00"
        for parsed in [
            AppDateFormatters.parseTimestamp(server),
            TransactionInstant.parse(server),
            BudgetMath.parseCreatedAt(server),
            SavingsViewModel.parseTimestamp(server),
        ] {
            XCTAssertEqual(parsed.map { $0.timeIntervalSince(sample) } ?? .nan, 0.123456, accuracy: 0.001)
        }
        XCTAssertEqual(TransactionInstant.parse("2026-11-17"), instant(2026, 11, 17, in: AppDateFormatters.utcTimeZone))
        XCTAssertEqual(SavingsViewModel.parseTimestamp("2026-11-17"), instant(2026, 11, 17, in: AppDateFormatters.utcTimeZone))
    }

    func test_transactionFormDates_roundTripTheWallClock() {
        let written = TransactionFormDates.string(from: sample, timeZone: bangkok)
        XCTAssertEqual(written, "2026-11-17T13:05:00")
        // Postgres hands the wall clock back with a +00 suffix.
        XCTAssertEqual(
            TransactionFormDates.parse(rawDateTime: written + "+00:00", fallbackDate: "2026-11-17", timeZone: bangkok),
            sample
        )
        XCTAssertEqual(
            TransactionFormDates.parse(rawDateTime: "2026-11-17", fallbackDate: "2026-11-17", timeZone: bangkok),
            instant(2026, 11, 17, in: bangkok)
        )
    }

    // MARK: - Engines that take the device calendar

    private func tx(_ id: String, _ type: TransactionType, _ date: String, _ amount: Int64) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: "a1", amount: amount, currency: "RUB",
            description: nil, categoryId: "c1", type: type, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private var rows: [Transaction] {
        [tx("t1", .expense, "2026-11-17", 1_000_00),
         tx("t2", .income, "2026-11-03", 5_000_00),
         tx("t3", .expense, "2026-10-31", 200_00)]
    }

    func test_cashFlowBuckets_buddhistCalendarMatchesGregorian() {
        let now = instant(2026, 12, 5, 12, 0, in: bangkok)
        let thai = CashFlowEngine.monthlyBuckets(transactions: rows, months: 3, now: now, calendar: buddhist)
        let greg = CashFlowEngine.monthlyBuckets(transactions: rows, months: 3, now: now, calendar: gregorian(bangkok))
        XCTAssertEqual(thai, greg)
        // Oldest-first is not guaranteed by the API; look the months up by content.
        XCTAssertTrue(thai.contains(CashFlowEngine.MonthlyBucket(income: 5_000_00, expense: 1_000_00)), "\(thai)")
        XCTAssertTrue(thai.contains(CashFlowEngine.MonthlyBucket(income: 0, expense: 200_00)), "\(thai)")
    }

    func test_insights_buddhistCalendarMatchesGregorian() {
        let input = InsightEngine.Input(
            transactions: rows, categories: [], budgets: [], subscriptions: [],
            formatAmount: { "\($0)" }, now: instant(2026, 11, 20, 12, 0, in: bangkok)
        )
        let thaiDigest = InsightEngine.weeklyDigest(input, calendar: buddhist)
        XCTAssertNotEqual(thaiDigest, String(localized: "insight.weeklyDigest.empty"))
        XCTAssertEqual(thaiDigest, InsightEngine.weeklyDigest(input, calendar: gregorian(bangkok)))
        XCTAssertEqual(
            InsightEngine.generate(input, calendar: buddhist),
            InsightEngine.generate(input, calendar: gregorian(bangkok))
        )
    }
}
