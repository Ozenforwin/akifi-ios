import XCTest
@testable import AkifiIOS

/// Covers `SettlementViewModel.watermark(from:)` — the "settlement line"
/// that decides which shared-account transactions count as already settled
/// via a cumulative `settlements` row (so they stop re-appearing as
/// "Ожидает расчёта" after a new expense reopens the net debt).
final class SettlementWatermarkTests: XCTestCase {

    private func makeSettlement(
        settledAt: String?,
        createdAt: String? = nil
    ) -> Settlement {
        Settlement(
            id: UUID().uuidString,
            sharedAccountId: "acc",
            fromUserId: "O",
            toUserId: "V",
            amount: 100_00,
            currency: "RUB",
            periodStart: "2026-01-01",
            periodEnd: "2026-06-01",
            settledAt: settledAt,
            settledBy: "V",
            createdAt: createdAt
        )
    }

    func test_empty_returnsNil() {
        XCTAssertNil(SettlementViewModel.watermark(from: []))
    }

    func test_picksLatestSettledAt() {
        let settlements = [
            makeSettlement(settledAt: "2026-05-10T08:00:00Z"),
            makeSettlement(settledAt: "2026-06-08T09:30:00Z"),
            makeSettlement(settledAt: "2026-06-01T12:00:00Z"),
        ]
        let mark = SettlementViewModel.watermark(from: settlements)
        XCTAssertNotNil(mark)

        // The latest of the three is 2026-06-08.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(mark, iso.date(from: "2026-06-08T09:30:00Z"))
    }

    func test_fallsBackToCreatedAt_whenSettledAtMissing() {
        let settlements = [
            makeSettlement(settledAt: nil, createdAt: "2026-04-20T10:00:00Z"),
        ]
        let mark = SettlementViewModel.watermark(from: settlements)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(mark, iso.date(from: "2026-04-20T10:00:00Z"))
    }

    func test_parsesFractionalSeconds() {
        let settlements = [
            makeSettlement(settledAt: "2026-06-08T09:30:00.123456Z"),
        ]
        XCTAssertNotNil(SettlementViewModel.watermark(from: settlements),
                        "Fractional-second ISO timestamps from the DB must parse")
    }

    /// A transaction dated the day after the last settle must fall OUTSIDE
    /// the watermark — that's the "new expense reopens the debt" case the
    /// fix must keep flagging as open.
    func test_transactionAfterWatermark_isNotCovered() {
        let mark = SettlementViewModel.watermark(
            from: [makeSettlement(settledAt: "2026-06-08T09:30:00Z")]
        )!
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"

        let before = parser.date(from: "2026-06-07")!
        let after = parser.date(from: "2026-06-09")!
        XCTAssertLessThanOrEqual(before, mark, "Row before the settle is covered")
        XCTAssertGreaterThan(after, mark, "Row after the settle stays open")
    }
}
