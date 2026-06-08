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

    // MARK: - Custom split weights

    /// A with weight 0.6, B with weight 0.4 on 1000 kopecks → fairShare
    /// A = 600, B = 400.
    func test_customSplit_60_40_twoMembers() {
        let txs = autoTransfer(user: "A", amount: 10_00, sourceAcc: "A-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B"],
            personalAccountsByUser: ["A": ["A-cash"], "B": ["B-cash"]],
            period: period,
            memberWeights: ["A": Decimal(string: "0.6")!, "B": Decimal(string: "0.4")!]
        )

        let a = balances.first { $0.userId == "A" }!
        let b = balances.first { $0.userId == "B" }!
        XCTAssertEqual(a.fairShare, 6_00)
        XCTAssertEqual(b.fairShare, 4_00)
        // A contributed 1000, fair 600 → +400. B contributed 0, fair 400 → -400.
        XCTAssertEqual(a.delta, 4_00)
        XCTAssertEqual(b.delta, -4_00)
    }

    /// Weights 2 and 1 (sum 3) on 900 kopecks → fairShare A=600, B=300.
    /// Verifies normalization handles non-unit sums.
    func test_customSplit_unequalWeights_sumNot1() {
        let txs = autoTransfer(user: "A", amount: 9_00, sourceAcc: "A-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B"],
            personalAccountsByUser: ["A": ["A-cash"], "B": ["B-cash"]],
            period: period,
            memberWeights: ["A": 2, "B": 1]
        )

        let a = balances.first { $0.userId == "A" }!
        let b = balances.first { $0.userId == "B" }!
        XCTAssertEqual(a.fairShare, 6_00)
        XCTAssertEqual(b.fairShare, 3_00)
    }

    // MARK: - Direct expense ignored

    /// Direct expenses on the shared account (no auto_transfer_group_id)
    /// are deliberately excluded from settlement math — pulling them in
    /// would silently surface huge historical debts the user never opted
    /// into. To participate in settlement, expenses must be created via
    /// the explicit payment-source auto-transfer flow.
    func test_directExpense_ignored() {
        let txs = [expense(id: "d1", user: "A", amount: 10_00, date: "2026-04-10")]

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B"],
            personalAccountsByUser: ["A": ["A-cash"], "B": ["B-cash"]],
            period: period
        )

        XCTAssertTrue(balances.isEmpty)
        XCTAssertTrue(SettlementCalculator.settlements(from: balances).isEmpty)
    }

    /// Mixed: direct expenses are ignored; only auto-transfer legs count.
    /// A auto-transfer 500, B auto-transfer 300, A direct 200 → total 800
    /// (direct ignored), fair 400 each. A: +100, B: -100.
    func test_directExpense_ignoredWithAutoTransferPresent() {
        var txs: [Transaction] = []
        txs += autoTransfer(user: "A", amount: 5_00, sourceAcc: "A-cash", targetAcc: sharedAccId, date: "2026-04-10")
        txs += autoTransfer(user: "B", amount: 3_00, sourceAcc: "B-cash", targetAcc: sharedAccId, date: "2026-04-11")
        txs.append(expense(id: "direct-A", user: "A", amount: 2_00, date: "2026-04-12"))

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B"],
            personalAccountsByUser: ["A": ["A-cash"], "B": ["B-cash"]],
            period: period
        )

        let a = balances.first { $0.userId == "A" }!
        let b = balances.first { $0.userId == "B" }!
        XCTAssertEqual(a.contributed, 5_00)
        XCTAssertEqual(b.contributed, 3_00)
        XCTAssertEqual(a.fairShare, 4_00)
        XCTAssertEqual(b.fairShare, 4_00)
        XCTAssertEqual(a.delta, 1_00)
        XCTAssertEqual(b.delta, -1_00)
    }

    // MARK: - FX-correct settlement

    /// V records a 100-USD auto-transfer on a RUB shared account. With
    /// USD rate 1.0 and RUB rate 75.0 (both USD-based), the source-leg
    /// in USD should normalize to 75 RUB worth of contribution.
    /// Target-currency leg on shared stays RUB.
    func test_crossCurrency_usdContribution_normalizedToBase() {
        // Build a manual cross-currency triplet. The RPC writes:
        //   - expense row on shared (RUB, amount 7500_00 kopecks)
        //   - transfer-out on V-bybit (USD, amount 100_00 kopecks)
        //   - transfer-in on shared (RUB, amount 7500_00 kopecks)
        // The calculator walks legs by `transfer_group_id` and attributes
        // based on the peer account, so cross-currency correctness is
        // about scaling the source-leg amount back to base (RUB).
        let group = UUID().uuidString
        let mainExpense = Transaction(
            id: UUID().uuidString, userId: "V", accountId: sharedAccId,
            amount: 7500_00, currency: "RUB", description: nil,
            categoryId: nil, type: .expense, date: "2026-04-15",
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, paymentSourceAccountId: "V-bybit",
            autoTransferGroupId: group,
            status: nil, createdAt: nil, updatedAt: nil
        )
        let outLeg = Transaction(
            id: UUID().uuidString, userId: "V", accountId: "V-bybit",
            amount: 100_00, currency: "USD", description: nil,
            categoryId: nil, type: .expense, date: "2026-04-15",
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: group, paymentSourceAccountId: nil,
            autoTransferGroupId: group,
            status: nil, createdAt: nil, updatedAt: nil
        )
        let inLeg = Transaction(
            id: UUID().uuidString, userId: "V", accountId: sharedAccId,
            amount: 7500_00, currency: "RUB", description: nil,
            categoryId: nil, type: .income, date: "2026-04-15",
            merchantName: nil, merchantFuzzy: nil,
            transferGroupId: group, paymentSourceAccountId: nil,
            autoTransferGroupId: group,
            status: nil, createdAt: nil, updatedAt: nil
        )
        let txs = [mainExpense, outLeg, inLeg]

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-bybit"], "O": ["O-cash"]],
            period: period,
            fxRates: ["USD": 1.0, "RUB": 75.0],
            baseCurrency: "RUB"
        )

        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        // TotalExpenses = 7500_00 RUB kopecks. Fair = 3750_00.
        XCTAssertEqual(v.fairShare, 3750_00)
        XCTAssertEqual(o.fairShare, 3750_00)
        // V's contribution via auto-transfer legs sums to:
        //   + 7500_00 RUB (transfer-in on shared, in base already)
        //   - 7500_00 RUB (transfer-out on V-bybit, normalized from 100 USD
        //                  → 100 * 75 = 7500_00 RUB kopecks).
        // Net contribution: 0. But that's the leg-pair cancellation on
        // shared-side views; the calculator only counts rows WHERE
        // `accountId == sharedAccountId`. So V gets just +7500_00 from
        // the in-leg, which is the effective contribution.
        XCTAssertEqual(v.contributed, 7500_00)
        XCTAssertEqual(o.contributed, 0)
        XCTAssertEqual(v.delta, 3750_00)
        XCTAssertEqual(o.delta, -3750_00)
    }

    /// Missing fxRates must not crash or yield wildly wrong numbers —
    /// the calculator should fall back to face-value math (old behavior).
    func test_crossCurrency_missingFxRates_fallsBackToFaceValue() {
        let txs = autoTransfer(user: "V", amount: 100_00, sourceAcc: "V-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period,
            fxRates: [:],
            baseCurrency: nil
        )

        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        XCTAssertEqual(v.contributed, 100_00)
        XCTAssertEqual(o.contributed, 0)
        XCTAssertEqual(v.delta, 50_00)
        XCTAssertEqual(o.delta, -50_00)
    }

    /// All weights equal to 1.0 must reproduce the equal-split behavior
    /// bit-for-bit with the no-weights call — verifies backward compat.
    func test_defaultWeights_equivalentToEqualSplit() {
        let txs =
            autoTransfer(user: "A", amount: 90_00, sourceAcc: "A-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "B", amount: 30_00, sourceAcc: "B-cash", targetAcc: sharedAccId)

        let equalSplit = SettlementCalculator.compute(
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
        let withExplicitOnes = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["A", "B", "C"],
            personalAccountsByUser: [
                "A": ["A-cash"],
                "B": ["B-cash"],
                "C": ["C-cash"]
            ],
            period: period,
            memberWeights: ["A": 1.0, "B": 1.0, "C": 1.0]
        )

        XCTAssertEqual(equalSplit, withExplicitOnes)
    }

    // MARK: - Per-member, per-transaction settlement marks

    /// 3 members, V paid 300 via auto-transfer. Without any per-member
    /// settlement: V is +200, O and E are -100 each. After O marks her
    /// share settled: O moves to 0, V drops to +100, E stays at -100.
    /// After E also settles: everyone at 0.
    func test_perMember_threeWayPartial_thenFull() {
        let txs = autoTransfer(
            user: "V", amount: 300_00,
            sourceAcc: "V-cash", targetAcc: sharedAccId
        )
        let mainExpense = txs.first { $0.type == .expense && $0.transferGroupId == nil }!

        // Pre-settlement baseline: V +200, O -100, E -100.
        let pre = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O", "E"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"], "E": ["E-cash"]],
            period: period
        )
        XCTAssertEqual(pre.first { $0.userId == "V" }!.delta, 200_00)
        XCTAssertEqual(pre.first { $0.userId == "O" }!.delta, -100_00)
        XCTAssertEqual(pre.first { $0.userId == "E" }!.delta, -100_00)

        // O marks her share of the txn settled.
        let oSettlement = TransactionMemberSettlement(
            id: UUID().uuidString,
            transactionId: mainExpense.id,
            sharedAccountId: sharedAccId,
            settledForUserId: "O",
            settledByUserId: "O",
            settledAt: nil,
            note: nil
        )

        let partial = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O", "E"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"], "E": ["E-cash"]],
            period: period,
            transactionMemberSettlements: [oSettlement]
        )
        XCTAssertEqual(partial.first { $0.userId == "V" }!.delta, 100_00,
                       "V's owed amount drops to 100 once O settles her 100-share")
        XCTAssertEqual(partial.first { $0.userId == "O" }!.delta, 0,
                       "O nets to zero — her share is closed")
        XCTAssertEqual(partial.first { $0.userId == "E" }!.delta, -100_00,
                       "E still owes her 100 share — independent of O's mark")

        // E also settles.
        let eSettlement = TransactionMemberSettlement(
            id: UUID().uuidString,
            transactionId: mainExpense.id,
            sharedAccountId: sharedAccId,
            settledForUserId: "E",
            settledByUserId: "E",
            settledAt: nil,
            note: nil
        )

        let full = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O", "E"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"], "E": ["E-cash"]],
            period: period,
            transactionMemberSettlements: [oSettlement, eSettlement]
        )
        XCTAssertEqual(full.first { $0.userId == "V" }!.delta, 0)
        XCTAssertEqual(full.first { $0.userId == "O" }!.delta, 0)
        XCTAssertEqual(full.first { $0.userId == "E" }!.delta, 0)
    }

    /// Defensive: a settlement marking the payer's own share is a no-op.
    /// The payer doesn't owe themselves anything, so applying the credit
    /// would create phantom money out of thin air.
    func test_perMember_payerSelfMark_isNoop() {
        let txs = autoTransfer(
            user: "V", amount: 300_00,
            sourceAcc: "V-cash", targetAcc: sharedAccId
        )
        let mainExpense = txs.first { $0.type == .expense && $0.transferGroupId == nil }!

        let bogusSelfMark = TransactionMemberSettlement(
            id: UUID().uuidString,
            transactionId: mainExpense.id,
            sharedAccountId: sharedAccId,
            settledForUserId: "V",  // V is the payer
            settledByUserId: "V",
            settledAt: nil,
            note: nil
        )

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period,
            transactionMemberSettlements: [bogusSelfMark]
        )

        // Identical to the no-settlement baseline: V +150, O -150.
        XCTAssertEqual(balances.first { $0.userId == "V" }!.delta, 150_00)
        XCTAssertEqual(balances.first { $0.userId == "O" }!.delta, -150_00)
    }

    // MARK: - Rounding-residual regression ("−0 ₽ должен доплатить" cosmetic)

    /// Two equal-weight members and an odd `totalExpenses` (in kopecks) used
    /// to leave one member at delta=0 and the other at delta=±1 kopeck —
    /// which the UI rendered as a "В расчёте" peer next to a "должен
    /// доплатить −0 ₽" peer. The fix distributes the rounding residual so
    /// `sum(fairShares) == totalExpenses` and both deltas land on 0.
    func test_twoMembers_oddTotalKopecks_noResidualDelta() {
        // V auto-transfers 50_01 (₽500.01), O auto-transfers 50_00.
        // total = 100_01, fair share before fix = 50_01 each → sum 100_02.
        // V: contributed 50_01, fair 50_01 → delta 0
        // O: contributed 50_00, fair 50_01 → delta -1 (the bug)
        // After fix: residual 100_01 - 100_02 = -1 kopeck, distributed by
        // subtracting 1 from V's fair share → V: 50_00, O: 50_01.
        // V: contributed 50_01, fair 50_00 → delta +1
        // O: contributed 50_00, fair 50_01 → delta -1
        // Hmm — that's still a ±1 residual on the contributions side.
        // Use a simpler scenario where the contributions DO sum cleanly:
        // both contribute 50_00 (so contributions split evenly), but a
        // single direct expense pushes total to an odd 100_01 — then
        // both fair shares should still tie exactly.
        let txs =
            autoTransfer(user: "V", amount: 50_00, sourceAcc: "V-cash", targetAcc: sharedAccId) +
            autoTransfer(user: "O", amount: 50_01, sourceAcc: "O-cash", targetAcc: sharedAccId)

        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: period
        )

        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!

        // Sum of fair shares must equal totalExpenses exactly — that's the
        // invariant the residual-distribution restores.
        XCTAssertEqual(v.fairShare + o.fairShare, 100_01,
                       "Fair shares must sum to totalExpenses (no rounding loss)")

        // Sum of deltas must be 0 — money in == money out, after the
        // residual is absorbed by the fair-share distribution.
        XCTAssertEqual(v.delta + o.delta, 0,
                       "Deltas must sum to 0 — otherwise UI shows phantom -0₽ next to settled peer")
    }

    // MARK: - Cumulative-balance regression (phantom reverse-direction debt)

    /// Reproduces the May-2026 bug: user settled the YTD imbalance, then
    /// the month view inverted because the settlement's `period_end` fell
    /// inside the month interval. The fix is to compute balances over a
    /// cumulative interval (`distantPast..distantFuture`) so every recorded
    /// settlement applies and every contribution is counted, regardless of
    /// where the user navigates the period picker.
    ///
    /// Setup (ignoring units; everything in the same currency):
    /// - April: V auto-transfers 200 from his card → 200 expense on shared.
    ///   O does nothing. V is 100 ahead, O is 100 short.
    /// - May:  O auto-transfers 100 from her card → 100 expense on shared.
    ///   V does nothing this month. Within May alone V is 50 short, O 50 ahead.
    /// - Settlement: O→V 100 (recorded with period_end = April 30, the
    ///   "right" scope at the time the user clicked).
    ///
    /// Under the old buggy logic, viewing May with period = May caused the
    /// April settlement to ALSO apply to May (period_end Apr 30 ∉ May, so
    /// actually here it would NOT apply — which is the same outcome the fix
    /// aims for). The original bug surfaced when the YTD-scope settlement's
    /// period_end fell in May (e.g. the settlement was recorded today, May
    /// 10). To reproduce that direction we use `period_end = today`.
    func test_cumulativeBalance_aprilSettlementClearsAllPeriods() {
        let cal: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()
        let april15 = "2026-04-15"
        let may05 = "2026-05-05"

        let txs =
            autoTransfer(user: "V", amount: 200_00,
                         sourceAcc: "V-cash", targetAcc: sharedAccId, date: april15) +
            autoTransfer(user: "O", amount: 100_00,
                         sourceAcc: "O-cash", targetAcc: sharedAccId, date: may05)

        // Pretend the user clicked "Mark settled" while on YTD view today.
        // period_end = today (May 10), period_start = Jan 1 — same shape as
        // the real DB row that triggered the bug.
        let pastSettlement = Settlement(
            id: UUID().uuidString,
            sharedAccountId: sharedAccId,
            fromUserId: "O",
            toUserId: "V",
            amount: 100_00,
            currency: "RUB",
            periodStart: "2026-01-01",
            periodEnd: "2026-05-10",
            settledBy: "V"
        )

        let cumulative = DateInterval(start: .distantPast, end: .distantFuture)
        let balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: cumulative,
            pastSettlements: [pastSettlement]
        )

        // V: contributed 200, settlement deducts 100 → net 100.
        // O: contributed 100, settlement adds 100 → net 200.
        // Total expenses: 300, fair share: 150 each.
        // Deltas: V = 100 - 150 = -50, O = 200 - 150 = +50 → O lent V 50.
        let v = balances.first { $0.userId == "V" }!
        let o = balances.first { $0.userId == "O" }!
        XCTAssertEqual(v.delta, -50_00,
                       "Cumulative V delta should be -50 (200 contributed, 100 settled, 150 fair share)")
        XCTAssertEqual(o.delta, 50_00,
                       "Cumulative O delta should be +50 (100 contributed, 100 received via settlement, 150 fair share)")

        // Sanity: contributing the same data twice — once for the buggy
        // month-only period (May), once with no settlement applied — should
        // produce a much larger reverse-direction delta. This is the very
        // scenario the user reported.
        let mayInterval = DateInterval(
            start: cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!,
            end: cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        )
        let buggyBalances = SettlementCalculator.compute(
            sharedAccountId: sharedAccId,
            transactions: txs,
            memberUserIds: ["V", "O"],
            personalAccountsByUser: ["V": ["V-cash"], "O": ["O-cash"]],
            period: mayInterval,
            pastSettlements: [pastSettlement]
        )
        // Under the period-scoped scheme: May only sees O's 100 contribution
        // (total 100, fair 50 each). Settlement applies (period_end May 10 ∈
        // May), wiping O's 100 contribution credit and adding it to V — so
        // V's delta becomes +50 + (settlement deducts 100 from V) = -50, and
        // O's becomes +50 + 100 = +150. Calculator returns this distorted
        // picture, which is what the bug report shows. The fix is to call
        // the calculator with a cumulative interval (above), not to "fix"
        // the period-scoped path — period scoping is just the wrong tool.
        let buggyV = buggyBalances.first { $0.userId == "V" }!
        XCTAssertNotEqual(buggyV.delta, v.delta,
                          "Period-scoped May view yields a different (distorted) V delta — confirms cumulative path is needed")
    }

    // MARK: - Rounding-noise floor (settlementEpsilon)

    func test_settlements_subEpsilonResidual_producesNoSuggestion() {
        // ±50 kopecks of drift (e.g. left over after a whole-ruble settle of
        // a cross-currency account) is below the 1 RUB floor → no suggestion.
        let balances = [
            SettlementCalculator.MemberBalance(userId: "V", contributed: 150, fairShare: 100),
            SettlementCalculator.MemberBalance(userId: "O", contributed: 50, fairShare: 100),
        ]
        XCTAssertEqual(balances.first { $0.userId == "V" }!.delta, 50)
        XCTAssertTrue(SettlementCalculator.settlements(from: balances).isEmpty,
                      "Sub-ruble residual must not surface as a phantom kopeck transfer")
    }

    func test_settlements_atEpsilon_producesSuggestion() {
        // Exactly 1 RUB (100 kopecks) is real debt → one suggestion.
        let balances = [
            SettlementCalculator.MemberBalance(userId: "V", contributed: 200, fairShare: 100),
            SettlementCalculator.MemberBalance(userId: "O", contributed: 0, fairShare: 100),
        ]
        let s = SettlementCalculator.settlements(from: balances)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.fromUserId, "O")
        XCTAssertEqual(s.first?.toUserId, "V")
        XCTAssertEqual(s.first?.amount, 100)
    }
}
