import XCTest
@testable import AkifiIOS

final class ChallengeProgressEngineTests: XCTestCase {

    // MARK: - Helpers

    private func tx(amount: Int64, type: TransactionType, categoryId: String? = nil,
                   date: String) -> Transaction {
        Transaction(
            id: UUID().uuidString, userId: "u1", accountId: "a1",
            amount: amount, currency: "RUB", description: nil,
            categoryId: categoryId, type: type, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func challenge(
        type: ChallengeType,
        target: Int64? = nil,
        categoryId: String? = "cafe",
        start: String = "2026-04-01",
        end: String = "2026-04-30",
        progress: Int64 = 0,
        status: ChallengeStatus = .active
    ) -> SavingsChallenge {
        SavingsChallenge(
            id: "ch1", userId: "u1",
            type: type, title: "Test", targetAmount: target,
            durationDays: 30, startDate: start, endDate: end,
            status: status, progressAmount: progress,
            categoryId: categoryId
        )
    }

    // MARK: - noCafe

    func testNoCafe_NoExpensesInCategory_ProgressZero() {
        let ch = challenge(type: .noCafe)
        let txs = [
            tx(amount: 100_00, type: .expense, categoryId: "other", date: "2026-04-10"),
            tx(amount: 500_00, type: .income, categoryId: nil, date: "2026-04-12")
        ]
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ([:], [:], "RUB")), 0)
    }

    func testNoCafe_ExpensesInCategory_AccumulatesViolations() {
        let ch = challenge(type: .noCafe)
        let txs = [
            tx(amount: 150_00, type: .expense, categoryId: "cafe", date: "2026-04-10"),
            tx(amount: 80_00, type: .expense, categoryId: "cafe", date: "2026-04-12"),
            // Outside range — ignored.
            tx(amount: 500_00, type: .expense, categoryId: "cafe", date: "2026-03-12")
        ]
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ([:], [:], "RUB")),
                       230_00)
    }

    func testNoCafe_TransfersIgnored() {
        let ch = challenge(type: .noCafe)
        var transfer = tx(amount: 200_00, type: .expense, categoryId: "cafe", date: "2026-04-10")
        transfer = Transaction(
            id: transfer.id, userId: transfer.userId, accountId: transfer.accountId,
            amount: transfer.amount, currency: transfer.currency, description: transfer.description,
            categoryId: transfer.categoryId, type: transfer.type, date: transfer.date,
            merchantName: transfer.merchantName, merchantFuzzy: transfer.merchantFuzzy,
            transferGroupId: "g1",
            status: transfer.status, createdAt: transfer.createdAt, updatedAt: transfer.updatedAt
        )
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: [transfer], currencyContext: ([:], [:], "RUB")), 0)
    }

    // MARK: - categoryLimit

    func testCategoryLimit_SumsCategoryExpenses() {
        let ch = challenge(type: .categoryLimit, target: 500_00)
        let txs = [
            tx(amount: 100_00, type: .expense, categoryId: "cafe", date: "2026-04-01"),
            tx(amount: 250_00, type: .expense, categoryId: "cafe", date: "2026-04-15"),
            tx(amount: 9000_00, type: .expense, categoryId: "food", date: "2026-04-20")
        ]
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ([:], [:], "RUB")),
                       350_00)
    }

    func testCategoryLimit_SuccessFractionMath() {
        var ch = challenge(type: .categoryLimit, target: 500_00)
        ch.progressAmount = 100_00
        // Spent 1/5 → 80 % remaining cushion.
        XCTAssertEqual(ch.successFraction, 0.8, accuracy: 0.01)
        ch.progressAmount = 500_00
        XCTAssertEqual(ch.successFraction, 0.0, accuracy: 0.01)
        ch.progressAmount = 600_00  // overspent
        XCTAssertEqual(ch.successFraction, 0.0, accuracy: 0.01)
    }

    // MARK: - roundUp

    func testRoundUp_SumsRoundupDeltas() {
        let ch = challenge(type: .roundUp, target: 1000_00, categoryId: nil)
        let txs = [
            tx(amount: 125_50, type: .expense, categoryId: "x", date: "2026-04-10"),  // delta 50
            tx(amount: 200_00, type: .expense, categoryId: "x", date: "2026-04-11"),  // delta 0
            tx(amount: 333_33, type: .expense, categoryId: "x", date: "2026-04-12")   // delta 67
        ]
        // 125_50 % 100 = 50 → +50. 200_00 % 100 = 0 → +0. 333_33 % 100 = 33 → +67.
        XCTAssertEqual(ChallengeProgressEngine.progress(for: ch, transactions: txs, currencyContext: ([:], [:], "RUB")),
                       50 + 0 + 67)
    }

    func testRoundUp_ConvertsEachDeltaFromItsOwnAccountCurrency() {
        // 1 USD = 100 RUB. A $1.50 coffee on a USD account rounds up by 50
        // cents = 50 ₽ (5 000 kopecks); summing raw deltas would have added
        // "50" as if it were 50 kopecks.
        let ch = challenge(type: .roundUp, target: 1000_00, categoryId: nil)
        var usd = tx(amount: 1_50, type: .expense, categoryId: "x", date: "2026-04-10")
        usd = Transaction(
            id: usd.id, userId: "u1", accountId: "usd-card",
            amount: 1_50, currency: "USD", description: nil,
            categoryId: "x", type: .expense, date: "2026-04-10",
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
        let accounts: [String: Account] = [
            "usd-card": Account(id: "usd-card", userId: "u1", name: "USD", icon: "", color: "", initialBalance: 0, currency: "USD", accountType: .checking),
        ]
        let rates: [String: Decimal] = ["USD": 1, "RUB": 100]
        XCTAssertEqual(
            ChallengeProgressEngine.progress(for: ch, transactions: [usd], currencyContext: (accounts, rates, "RUB")),
            50_00
        )
    }

    // MARK: - nextStatus

    func testNextStatus_CategoryLimitWithinTarget_PostPeriod_Completed() {
        var ch = challenge(type: .categoryLimit, target: 500_00)
        ch.progressAmount = 200_00
        let futureNow = Calendar.current.date(byAdding: .day, value: 10, to: {
            let df = AppDateFormatters.posix("yyyy-MM-dd", timeZone: .current); df.dateFormat = "yyyy-MM-dd"
            return df.date(from: "2026-04-30")!
        }())!
        XCTAssertEqual(ChallengeProgressEngine.nextStatus(for: ch, now: futureNow), .completed)
    }

    func testNextStatus_CategoryLimitOverspent_PostPeriod_Abandoned() {
        var ch = challenge(type: .categoryLimit, target: 500_00)
        ch.progressAmount = 900_00
        let futureNow = Calendar.current.date(byAdding: .day, value: 10, to: {
            let df = AppDateFormatters.posix("yyyy-MM-dd", timeZone: .current); df.dateFormat = "yyyy-MM-dd"
            return df.date(from: "2026-04-30")!
        }())!
        XCTAssertEqual(ChallengeProgressEngine.nextStatus(for: ch, now: futureNow), .abandoned)
    }

    func testNextStatus_NonActive_ReturnsNil() {
        let ch = challenge(type: .categoryLimit, target: 500_00, status: .completed)
        XCTAssertNil(ChallengeProgressEngine.nextStatus(for: ch))
    }

    func testNextStatus_WeeklyAmountEarlyHitTarget_Completed() {
        var ch = challenge(type: .weeklyAmount, target: 1000_00)
        ch.progressAmount = 1200_00
        XCTAssertEqual(ChallengeProgressEngine.nextStatus(for: ch), .completed)
    }
}
