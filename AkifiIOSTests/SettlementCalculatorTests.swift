import XCTest
@testable import AkifiIOS

/// Tests for the pure settlement engine. See `SettlementCalculator` for the
/// algorithm contract. All transaction shapes mirror what the Supabase RPC
/// `create_expense_with_auto_transfer` produces — a three-row triplet per
/// contribution event (main expense + transfer pair), all sharing the same
/// `autoTransferGroupId`.
final class SettlementCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private let sharedAccId = "shared-1"
    private let periodStart: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 4, day: 1))!
    }()
    private let periodEnd: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 4, day: 30))!
    }()

    private var period: DateInterval { DateInterval(start: periodStart, end: periodEnd) }

    private func expense(id: String = UUID().uuidString, user: String,
                        amount: Int64, date: String = "2026-04-15") -> Transaction {
        Transaction(
            id: id, userId: user, accountId: sharedAccId,
            amount: amount, currency: "RUB", description: nil,
            categoryId: nil, type: .expense, date: date,
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, paymentSourceAccountId: nil,
            autoTransferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    /// Builds a triplet (expense on target + transfer-out on source + transfer-in on target)
    /// that mirrors what the RPC `create_expense_with_auto_transfer` produces.
    /// Returns all three rows so the calculator can walk `autoTransferGroupId`.
    private func autoTransfer(user: String, amount: Int64, sourceAcc: String,
                              targetAcc: String, date: String = "2026-04-15") -> [Transaction] {
        let group = UUID().uuidString
        let mainExpense = Transaction(
            id: UUID().uuidString, userId: user, accountId: targetAcc,
            amount: amount, currency: "RUB", description: nil,
            categoryId: nil, type: .expense, date: date,
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, paymentSourceAccountId: sourceAcc,
            autoTransferGroupId: group,
            status: nil, createdAt: nil, updatedAt: nil
        )
        let outLeg = Transaction(
            id: UUID().uuidString, userId: user, accountId: sourceAcc,
            amount: amount, currency: "RUB", description: nil,
            categoryId: nil, type: .expense, date: date,
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: group, paymentSourceAccountId: nil,
            autoTransferGroupId: group,
            status: nil, createdAt: nil, updatedAt: nil
        )
        let inLeg = Transaction(
            id: UUID().uuidString, userId: user, accountId: targetAcc,
            amount: amount, currency: "RUB", description: nil,
            categoryId: nil, type: .income, date: date,
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: group, paymentSourceAccountId: nil,
            autoTransferGroupId: group,
            status: nil, createdAt: nil, updatedAt: nil
        )
        return [mainExpense, outLeg, inLeg]
    }

    // MARK: - 2-member base case (both even)

    /// V paid 50k auto-transfer, O paid 50k auto-transfer → total 100k
    /// spent on shared, fair share 50k each, both balances == 0.
    func test_twoMembers_equalContributions_evenSplit() {
        let txs =
            autoTransfer(user: "V", amount: 50_00, sourceAcc: "V-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "O", amount: 50_00, sourceAcc: "O-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period
        )

        XCTAssertEqual(balances.count, 2)
        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        XCTAssertEqual(v.contributed, 50_00)
        XCTAssertEqual(o.contributed, 50_00)
        XCTAssertEqual(v.fairShare, 50_00)
        XCTAssertEqual(o.fairShare, 50_00)
        XCTAssertEqual(v.delta, 0)
        XCTAssertEqual(o.delta, 0)

        XCTAssertTrue(SettlementCalculator.settlements(from: balances).isEmpty)
    }

    // MARK: - 2 members, one overpaid

    /// V auto-transferred 100k, O auto-transferred 50k. Total shared expenses
    /// 150k, fair = 75k each. V: +25k, O: -25k → O pays V 25k.
    func test_twoMembers_oneOverpaid_onePaySuggestion() {
        let txs =
            autoTransfer(user: "V", amount: 100_00, sourceAcc: "V-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "O", amount: 50_00, sourceAcc: "O-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period
        )

        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        XCTAssertEqual(v.delta, 25_00)
        XCTAssertEqual(o.delta, -25_00)

        let suggestions = SettlementCalculator.settlements(from: balances)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].fromUserId, "O")
        XCTAssertEqual(suggestions[0].toUserId, "V")
        XCTAssertEqual(suggestions[0].amount, 25_00)
    }

    // MARK: - 3 members, unequal contributions

    /// A: 90k, B: 30k, C: 0k. Total 120k, fair = 40k each.
    /// Deltas: A +50, B -10, C -40. Greedy settlement: C→A 40, then B→A 10.
    func test_threeMembers_unequalContributions() {
        let txs =
            autoTransfer(user: "A", amount: 90_00, sourceAcc: "A-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "B", amount: 30_00, sourceAcc: "B-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B", "C"],
            personalAccountsByUser: [
                "A": ["A-cash"],
                "B": ["B-cash"],
                "C": ["C-cash"]
            ],
            period: period
        )

        let a = balances.first { $0.userId == "A" }!
        let b = balances.first { $0.userId == "B" }!
        let c = balances.first { $0.userId == "C" }!
        XCTAssertEqual(a.delta, 50_00)
        XCTAssertEqual(b.delta, -10_00)
        XCTAssertEqual(c.delta, -40_00)

        let suggestions = SettlementCalculator.settlements(from: balances)
        XCTAssertEqual(suggestions.count, 2)
        // Largest debtor (C, -40) pays largest creditor (A, +50) 40.
        XCTAssertEqual(suggestions[0].fromUserId, "C")
        XCTAssertEqual(suggestions[0].toUserId, "A")
        XCTAssertEqual(suggestions[0].amount, 40_00)
        // Remainder: B pays A 10.
        XCTAssertEqual(suggestions[1].fromUserId, "B")
        XCTAssertEqual(suggestions[1].toUserId, "A")
        XCTAssertEqual(suggestions[1].amount, 10_00)
    }

    // MARK: - All equal, delta=0 across all members

    func test_threeMembers_allEqualContributions_noSettlements() {
        let txs =
            autoTransfer(user: "A", amount: 30_00, sourceAcc: "A-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "B", amount: 30_00, sourceAcc: "B-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "C", amount: 30_00, sourceAcc: "C-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B", "C"],
            personalAccountsByUser: [
                "A": ["A-cash"],
                "B": ["B-cash"],
                "C": ["C-cash"]
            ],
            period: period
        )

        for b in balances { XCTAssertEqual(b.delta, 0) }
        XCTAssertTrue(SettlementCalculator.settlements(from: balances).isEmpty)
    }

    // MARK: - One member contributed nothing

    /// V auto-transferred 100k, O nothing. Total 100k, fair 50k each.
    /// V +50, O -50 → O→V 50.
    func test_twoMembers_oneContributedNothing() {
        let txs = autoTransfer(user: "V", amount: 100_00, sourceAcc: "V-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period
        )

        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        XCTAssertEqual(v.contributed, 100_00)
        XCTAssertEqual(o.contributed, 0)
        XCTAssertEqual(v.delta, 50_00)
        XCTAssertEqual(o.delta, -50_00)

        let suggestions = SettlementCalculator.settlements(from: balances)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].fromUserId, "O")
        XCTAssertEqual(suggestions[0].toUserId, "V")
        XCTAssertEqual(suggestions[0].amount, 50_00)
    }

    // MARK: - One member overpaid 2x

    /// V auto-transferred 200k total across two events, O nothing.
    /// Total shared spend 200k, fair 100k each. V +100, O -100 → O→V 100.
    func test_twoMembers_overpaidDoubleTheNeed() {
        let txs =
            autoTransfer(user: "V", amount: 100_00, sourceAcc: "V-cash", targetAcc: sharedAccId, date: "2026-04-10") +
            autoTransfer(user: "V", amount: 100_00, sourceAcc: "V-cash", targetAcc: sharedAccId, date: "2026-04-20")

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period
        )

        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        XCTAssertEqual(v.contributed, 200_00)
        XCTAssertEqual(v.fairShare, 100_00)
        XCTAssertEqual(v.delta, 100_00)
        XCTAssertEqual(o.delta, -100_00)

        let suggestions = SettlementCalculator.settlements(from: balances)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].amount, 100_00)
    }

    // MARK: - Empty period (0 expenses)

    func test_emptyPeriod_noExpenses_balancesAllZero() {
        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: [],
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period
        )
        // With no auto-transfer expenses in the period, we return an empty
        // array so the UI shows the "nothing to settle yet" empty state
        // instead of displaying every member with zero delta.
        XCTAssertTrue(balances.isEmpty)
        XCTAssertTrue(SettlementCalculator.settlements(from: balances).isEmpty)
    }

}
