import XCTest
@testable import AkifiIOS

final class StreakTrackerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StreakTracker.resetCelebrationState()
    }

    override func tearDown() {
        StreakTracker.resetCelebrationState()
        super.tearDown()
    }

    // MARK: - Helpers

    private func tx(on date: String) -> Transaction {
        Transaction(
            id: UUID().uuidString, userId: "u1", accountId: "a1",
            amount: 100_00, currency: "RUB", description: nil,
            categoryId: nil, type: .expense, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private static let isoFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func todayString(offset: Int = 0) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: Date())!
        return Self.isoFormatter.string(from: date)
    }

    // MARK: - Streak calc

    func testCurrentStreak_EmptyTransactions_ReturnsZero() {
        XCTAssertEqual(StreakTracker.currentStreak(from: []), 0)
    }

    func testCurrentStreak_NoTxToday_ReturnsZero() {
        // Tx yesterday only — no streak continues into today.
        let txs = [tx(on: todayString(offset: -1))]
        XCTAssertEqual(StreakTracker.currentStreak(from: txs), 0)
    }

    func testCurrentStreak_ThreeConsecutiveDaysIncludingToday_ReturnsThree() {
        let txs = [
            tx(on: todayString(offset: 0)),
            tx(on: todayString(offset: -1)),
            tx(on: todayString(offset: -2))
        ]
        XCTAssertEqual(StreakTracker.currentStreak(from: txs), 3)
    }

    func testCurrentStreak_WithGap_StopsAtGap() {
        let txs = [
            tx(on: todayString(offset: 0)),
            tx(on: todayString(offset: -1)),
            // gap at -2
            tx(on: todayString(offset: -3))
        ]
        XCTAssertEqual(StreakTracker.currentStreak(from: txs), 2)
    }

    // MARK: - Milestone detection

    func testDetectNewMilestone_BelowFirst_ReturnsNil() {
        XCTAssertNil(StreakTracker.detectNewMilestone(currentStreak: 6))
    }

    func testDetectNewMilestone_ExactlySeven_ReturnsSeven() {
        XCTAssertEqual(StreakTracker.detectNewMilestone(currentStreak: 7), 7)
    }

    func testDetectNewMilestone_SecondCallSameStreak_ReturnsNil() {
        _ = StreakTracker.detectNewMilestone(currentStreak: 7)
        XCTAssertNil(StreakTracker.detectNewMilestone(currentStreak: 7))
    }

    func testDetectNewMilestone_JumpsTwoLevels_ReturnsHigher() {
        // User goes 5→35 without app opening in between. We should celebrate
        // the highest new milestone (30), not emit two popups.
        XCTAssertEqual(StreakTracker.detectNewMilestone(currentStreak: 35), 30)
    }

    func testDetectNewMilestone_AfterCelebrating7_OnlyCelebrates14OnceReached() {
        _ = StreakTracker.detectNewMilestone(currentStreak: 7)
        XCTAssertNil(StreakTracker.detectNewMilestone(currentStreak: 10))
        XCTAssertEqual(StreakTracker.detectNewMilestone(currentStreak: 14), 14)
    }

    // MARK: - Info

    func testInfo_Known7_IsBronze() {
        XCTAssertEqual(StreakTracker.info(for: 7).tier, .bronze)
    }

    func testInfo_Known100_IsGold() {
        XCTAssertEqual(StreakTracker.info(for: 100).tier, .gold)
    }

    func testInfo_Known365_IsDiamond() {
        XCTAssertEqual(StreakTracker.info(for: 365).tier, .diamond)
    }
}
