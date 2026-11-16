import XCTest
@testable import AkifiIOS

/// Reports pager after month navigation, CSV export bounds, the historical
/// FX date, and the streak walk.
@MainActor
final class ReportsAndExportDateTests: XCTestCase {

    private func day(_ s: String) -> Date { AppDateFormatters.isoDate.date(from: s)! }
    private func at(_ s: String) -> Date { AppDateFormatters.localDateTime.date(from: s)! }

    private func tx(_ date: String, account: String = "a1") -> Transaction {
        Transaction(
            id: "tx-\(date)-\(account)", userId: "u1", accountId: account, amount: 100_00, currency: "RUB",
            description: nil, categoryId: nil, type: .expense, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    // MARK: - Reports pager

    /// September picked in month mode, then quarter mode: Q4 holds today
    /// (17 Nov), so "next" must exist. September + 3 months = December was
    /// in the future and the button disappeared.
    func test_quarterNext_afterMonthNavigation() {
        let vm = ReportsViewModel()
        vm.periodMode = .month
        vm.selectedMonth = day("2026-09-01")
        vm.periodMode = .quarter

        let now = at("2026-11-17T12:00:00")
        XCTAssertEqual(vm.nextPeriodDate(now: now), day("2026-10-01"))
        vm.nextPeriod(now: now)
        XCTAssertEqual(vm.selectedMonth, day("2026-10-01"))
        XCTAssertNil(vm.nextPeriodDate(now: now), "Q1 2027 has not started")
    }

    func test_yearNext_afterMonthNavigation() {
        let vm = ReportsViewModel()
        vm.periodMode = .month
        vm.selectedMonth = day("2025-12-01")
        vm.periodMode = .year

        let now = at("2026-11-17T12:00:00")
        XCTAssertEqual(vm.nextPeriodDate(now: now), day("2026-01-01"))
        vm.nextPeriod(now: now)
        XCTAssertNil(vm.nextPeriodDate(now: now))
    }

    func test_quarterPrevious_stepsFromThePeriodStart() {
        let vm = ReportsViewModel()
        vm.periodMode = .quarter
        vm.selectedMonth = day("2026-09-01")
        XCTAssertEqual(vm.prevPeriodDate(), day("2026-04-01"))
    }

    func test_monthMode_unchanged() {
        let vm = ReportsViewModel()
        vm.periodMode = .month
        vm.selectedMonth = day("2026-10-01")
        let now = at("2026-11-17T12:00:00")
        XCTAssertEqual(vm.nextPeriodDate(now: now), day("2026-11-01"))
        vm.selectedMonth = day("2026-11-01")
        XCTAssertNil(vm.nextPeriodDate(now: now))
    }

    // MARK: - CSV export

    func test_export_includesTheWholeFromDay() {
        // DatePickers carry the current time of day.
        let from = at("2026-11-01T15:42:00")
        let to = at("2026-11-17T09:00:00")
        let txs = [tx("2026-10-31"), tx("2026-11-01"), tx("2026-11-17"), tx("2026-11-18")]
        XCTAssertEqual(ExportView.filter(txs, from: from, to: to, accountId: nil).map(\.date),
                       ["2026-11-01", "2026-11-17"])
    }

    func test_export_accountFilterAndSwappedBounds() {
        let txs = [tx("2026-11-05", account: "a1"), tx("2026-11-05", account: "a2")]
        let r = ExportView.filter(txs, from: at("2026-11-10T10:00:00"), to: at("2026-11-01T10:00:00"), accountId: "a2")
        XCTAssertEqual(r.map(\.accountId), ["a2"])
    }

    // MARK: - Historical FX date

    /// ExchangeRateService renders the Date with ISO8601 `.withFullDate`
    /// (UTC). The reconciliation screen now hands it UTC midnight of the
    /// transaction's day, so the requested day is the transaction's day in
    /// every time zone. Local midnight in UTC+7 rendered as the day before.
    func test_reconciliationRequestsTheTransactionsOwnDay() {
        let iso = ISO8601DateFormatter() // date-formatter-ok: mirrors ExchangeRateService
        iso.formatOptions = [.withFullDate]
        let passed = AppDateFormatters.utcDate.date(from: "2026-11-17")!
        XCTAssertEqual(iso.string(from: passed), "2026-11-17")

        let localMidnightUTCPlus7 = AppDateFormatters.localDate(in: TimeZone(secondsFromGMT: 7 * 3600)!)
            .date(from: "2026-11-17")!
        XCTAssertEqual(iso.string(from: localMidnightUTCPlus7), "2026-11-16", "the old bug")
    }

    // MARK: - Streak

    func test_streak_walksLocalDayStrings() {
        let now = at("2026-11-17T00:30:00")
        let txs = [tx("2026-11-17"), tx("2026-11-16"), tx("2026-11-15"), tx("2026-11-13")]
        XCTAssertEqual(StreakTracker.currentStreak(from: txs, now: now), 3)
        XCTAssertEqual(StreakTracker.currentStreak(from: [tx("2026-11-16")], now: now), 0)
    }
}
