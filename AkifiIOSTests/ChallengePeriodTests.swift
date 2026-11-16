import XCTest
@testable import AkifiIOS

/// D10 (challenges): length, days left, savings flow, end-of-period status.
final class ChallengePeriodTests: XCTestCase {

    private func at(_ s: String) -> Date { AppDateFormatters.localDateTime.date(from: s)! }

    private func challenge(
        _ type: ChallengeType,
        start: String = "2026-11-17",
        end: String = "2026-11-24",
        target: Int64? = nil,
        categoryId: String? = nil,
        progress: Int64 = 0
    ) -> SavingsChallenge {
        SavingsChallenge(
            id: "ch", userId: "u1", type: type, title: "t", targetAmount: target,
            durationDays: 7, startDate: start, endDate: end, progressAmount: progress,
            categoryId: categoryId
        )
    }

    private func tx(
        _ date: String,
        _ type: TransactionType,
        amount: Int64 = 500_00,
        account: String = "checking",
        categoryId: String? = nil,
        transferGroupId: String? = nil,
        autoTransferGroupId: String? = nil
    ) -> Transaction {
        Transaction(
            id: UUID().uuidString, userId: "u1", accountId: account, amount: amount, currency: "RUB",
            description: nil, categoryId: categoryId, type: type, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: transferGroupId,
            autoTransferGroupId: autoTransferGroupId,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private var ctx: TransactionMath.CurrencyContext {
        let accounts = [
            Account(id: "checking", userId: "u1", name: "Card", icon: "", color: "", initialBalance: 0, currency: "RUB", accountType: .checking),
            Account(id: "savings", userId: "u1", name: "Piggy", icon: "", color: "", initialBalance: 0, currency: "RUB", accountType: .savings),
        ]
        return (Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) }), [:], "RUB")
    }

    // MARK: - Length

    func test_sevenDayChallenge_coversSevenDays() {
        let p = SavingsChallengesViewModel.period(durationDays: 7, now: at("2026-11-17T23:30:00"))
        XCTAssertEqual(p.start, "2026-11-17")
        XCTAssertEqual(p.end, "2026-11-24", "end is exclusive: 17…23 = 7 days")

        let ch = challenge(.categoryLimit, target: 10_000_00, categoryId: "cafe")
        let days = (17...24).map { String(format: "2026-11-%02d", $0) }
        let txs = days.map { tx($0, .expense, amount: 100_00, categoryId: "cafe") }
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ctx),
                       7 * 100_00, "the 24th is outside — it used to be day 8")
    }

    func test_daysRemaining_onFirstAndLastDay() {
        let ch = challenge(.noCafe, categoryId: "cafe")
        XCTAssertEqual(ch.daysLeft(now: at("2026-11-17T08:00:00")), 7)
        XCTAssertEqual(ch.daysLeft(now: at("2026-11-23T00:10:00")), 1, "last day still counts")
        XCTAssertEqual(ch.daysLeft(now: at("2026-11-23T23:50:00")), 1)
        XCTAssertEqual(ch.daysLeft(now: at("2026-11-24T00:10:00")), 0)
    }

    func test_isFinished_flipsAtTheExclusiveEnd() {
        let ch = challenge(.noCafe, categoryId: "cafe")
        XCTAssertFalse(ch.isFinished(now: at("2026-11-23T23:59:00")))
        XCTAssertTrue(ch.isFinished(now: at("2026-11-24T00:00:00")))
    }

    func test_lastDay_isTheDayBeforeEndDate() {
        let ch = challenge(.noCafe)
        XCTAssertEqual(ch.lastDay.map { AppDateFormatters.isoDate.string(from: $0) }, "2026-11-23")
    }

    // MARK: - noCafe resolves at the end

    func test_noCafe_violated_failsAtTheEnd() {
        let ch = challenge(.noCafe, categoryId: "cafe", progress: 350_00)
        XCTAssertNil(ChallengeProgressEngine.nextStatus(for: ch, now: at("2026-11-23T12:00:00")))
        XCTAssertEqual(ChallengeProgressEngine.nextStatus(for: ch, now: at("2026-11-24T09:00:00")), .abandoned)
    }

    func test_noCafe_clean_completesAtTheEnd() {
        let ch = challenge(.noCafe, categoryId: "cafe", progress: 0)
        XCTAssertNil(ChallengeProgressEngine.nextStatus(for: ch, now: at("2026-11-20T12:00:00")))
        XCTAssertEqual(ChallengeProgressEngine.nextStatus(for: ch, now: at("2026-11-24T09:00:00")), .completed)
    }

    func test_roundUpWithoutTarget_completesAtTheEnd() {
        let ch = challenge(.roundUp, progress: 47_00)
        XCTAssertNil(ChallengeProgressEngine.nextStatus(for: ch, now: at("2026-11-20T12:00:00")))
        XCTAssertEqual(ChallengeProgressEngine.nextStatus(for: ch, now: at("2026-11-24T09:00:00")), .completed)
    }

    // MARK: - weeklyAmount counts savings, not income

    func test_weeklyAmount_salaryDoesNotCount() {
        let ch = challenge(.weeklyAmount, target: 500_00)
        let salary = tx("2026-11-18", .income, amount: 150_000_00)
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: [salary], currencyContext: ctx), 0)
    }

    func test_weeklyAmount_transferIntoSavingsAccountCounts() {
        let ch = challenge(.weeklyAmount, target: 500_00)
        let txs = [
            tx("2026-11-18", .expense, amount: 500_00, account: "checking", transferGroupId: "g1"),
            tx("2026-11-18", .income, amount: 500_00, account: "savings", transferGroupId: "g1"),
            // Between everyday accounts — not saving.
            tx("2026-11-19", .income, amount: 300_00, account: "checking", transferGroupId: "g2"),
            // Auto-transfer leg ("paid from") — bookkeeping.
            tx("2026-11-19", .income, amount: 200_00, account: "savings", transferGroupId: "g3", autoTransferGroupId: "a3"),
            // Outside the period.
            tx("2026-11-24", .income, amount: 900_00, account: "savings", transferGroupId: "g4"),
        ]
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ctx), 500_00)
    }

    func test_weeklyAmount_withCategory_countsOnlyThatCategory() {
        let ch = challenge(.weeklyAmount, target: 500_00, categoryId: "savings-cat")
        let txs = [
            tx("2026-11-18", .expense, amount: 400_00, categoryId: "savings-cat"),
            tx("2026-11-18", .income, amount: 90_000_00, categoryId: "salary"),
        ]
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ctx), 400_00)
    }
}
