import XCTest
@testable import AkifiIOS

/// `SettlementCalculator` (the offline fallback and cross-check) follows
/// the v2 rules of `get_account_settlement` (contract §B4/§B6). The
/// fixture is the one `supabase/tests/20261128090003_account_settlement_v2.assert.sql`
/// builds, step by step, with the same expected numbers:
///   E1 shared 100.00 paid by A from A's card          → 50/50
///   E2 B's personal 30.00 paid by B from B's card     → nets to zero for B
///   E3 B's personal 40.00 paid by A from A's card     → B owes A the full 40
///   E4 B's personal 25.00 from S's own money          → B owes S 25
///   R1 B repays 10.00, R2 B repays 20.00 more         → owed 15, then 0
final class SettlementV2ParityTests: XCTestCase {

    let a = "aaaa-0000"   // owner; sorts first like the server's member order
    let b = "bbbb-0000"   // editor
    let s = "shared"
    let ca = "card-a"
    let cb = "card-b"

    private var seq = 0
    private func stamp() -> String {
        seq += 1
        return String(format: "2026-11-28T10:%02d:00+00:00", seq)
    }

    private func tx(_ id: String, user: String, account: String, _ type: TransactionType, _ rub: Int64,
                    tg: String? = nil, ag: String? = nil, personal: String? = nil) -> Transaction {
        Transaction(id: id, userId: user, accountId: account, amount: rub * 100, currency: "RUB", description: nil,
                    categoryId: nil, type: type, date: "2026-11-28", rawDateTime: "2026-11-28T10:00:00",
                    merchantName: nil, merchantFuzzy: nil, transferGroupId: tg, paymentSourceAccountId: nil,
                    autoTransferGroupId: ag, personalDebtUserId: personal, status: nil, createdAt: stamp(), updatedAt: nil)
    }

    /// `create_expense_with_auto_transfer`: main expense + out leg + in leg,
    /// all written by the payer.
    private func autoExpense(_ id: String, payer: String, card: String, _ rub: Int64, personal: String? = nil) -> [Transaction] {
        let g = "atg-\(id)"
        var main = tx(id, user: payer, account: s, .expense, rub, ag: g, personal: personal)
        main.paymentSourceAccountId = card
        return [
            main,
            tx("\(id)-out", user: payer, account: card, .expense, rub, tg: g, ag: g),
            tx("\(id)-in", user: payer, account: s, .income, rub, tg: g, ag: g),
        ]
    }

    private func repayment(_ id: String, by user: String, card: String, _ rub: Int64) -> [Transaction] {
        let g = "rep-\(id)"
        return [
            tx("\(id)-out", user: user, account: card, .expense, rub, tg: g),
            tx("\(id)-in", user: user, account: s, .income, rub, tg: g, personal: user),
        ]
    }

    private func compute(_ txs: [Transaction], members: [String]? = nil, marks: [TransactionMemberSettlement] = []) -> [String: SettlementCalculator.MemberBalance] {
        let balances = SettlementCalculator.compute(
            sharedAccountId: s,
            transactions: txs,
            memberUserIds: members ?? [a, b],
            personalAccountsByUser: [a: [ca], b: [cb]],
            period: DateInterval(start: .distantPast, end: .distantFuture),
            transactionMemberSettlements: marks
        )
        return Dictionary(uniqueKeysWithValues: balances.map { ($0.userId, $0) })
    }

    private func mark(_ txId: String, for user: String, by marker: String) -> TransactionMemberSettlement {
        TransactionMemberSettlement(id: UUID().uuidString, transactionId: txId, sharedAccountId: s,
                                    settledForUserId: user, settledByUserId: marker, settledAt: nil, note: nil)
    }

    func test_sqlFixture_stepByStep() {
        // (e) E1 only: v1 behaviour.
        var txs = autoExpense("e1", payer: a, card: ca, 100)
        var r = compute(txs)
        XCTAssertEqual(r[a]?.delta, 5000)
        XCTAssertEqual(r[b]?.delta, -5000)
        XCTAssertEqual(r[a]?.personalShare, 0)

        // (a) E2: B's personal via B's card → no effect on B's delta.
        txs += autoExpense("e2", payer: b, card: cb, 30, personal: b)
        r = compute(txs)
        XCTAssertEqual(r[b]?.delta, -5000)
        XCTAssertEqual(r[b]?.fairShare, 8000)
        XCTAssertEqual(r[b]?.personalShare, 3000)
        XCTAssertEqual(r[b]?.contributed, 3000)

        // (b) E3: B's personal paid by A → B owes A the full 40.
        txs += autoExpense("e3", payer: a, card: ca, 40, personal: b)
        r = compute(txs)
        XCTAssertEqual(r[a]?.delta, 9000)
        XCTAssertEqual(r[b]?.delta, -9000)
        XCTAssertEqual(r.values.map(\.fairShare).reduce(0, +), 17000, "Σ fair_share = total_expenses")

        // (c) E4: B's personal from S's own money → owed to the account;
        // the who-owes-whom balances don't move.
        txs.append(tx("e4", user: b, account: s, .expense, 25, personal: b))
        r = compute(txs)
        XCTAssertEqual(r[b]?.delta, -9000)
        var pd = SettlementCalculator.personalDebts(sharedAccountId: s, transactions: txs, memberUserIds: [a, b])
        XCTAssertEqual(pd.count, 2, "one entry per current member, zeros included")
        XCTAssertEqual(pd.first { $0.userId == b }, SettlementCalculator.PersonalDebt(userId: b, expenses: 2500, repaid: 0, isMember: true))
        XCTAssertEqual(pd.first { $0.userId == a }?.owed, 0)

        // (d) R1: partial repayment card B → S.
        txs += repayment("r1", by: b, card: cb, 10)
        r = compute(txs)
        XCTAssertEqual(r[b]?.delta, -9000, "a repayment is not part of the balances")
        pd = SettlementCalculator.personalDebts(sharedAccountId: s, transactions: txs, memberUserIds: [a, b])
        let pdB = pd.first { $0.userId == b }
        XCTAssertEqual(pdB?.owed, 1500)
        XCTAssertEqual(pdB?.expenses, 2500)
        XCTAssertEqual(pdB?.repaid, 1000)

        // R2: over-repayment clamps owed at 0, raw numbers stay.
        txs += repayment("r2", by: b, card: cb, 20)
        pd = SettlementCalculator.personalDebts(sharedAccountId: s, transactions: txs, memberUserIds: [a, b])
        XCTAssertEqual(pd.first { $0.userId == b }?.owed, 0)
        XCTAssertEqual(pd.first { $0.userId == b }?.repaid, 3000)

        // Per-transaction marks: B's share of E3 is all of it; a mark for A
        // on E2 (B's personal, B paid) is a no-op.
        r = compute(txs, marks: [mark("e3", for: b, by: a), mark("e2", for: a, by: a)])
        XCTAssertEqual(r[b]?.delta, -5000)
        XCTAssertEqual(r[a]?.delta, 5000)

        // Unmarking E3 makes it shared again.
        if let i = txs.firstIndex(where: { $0.id == "e3" }) { txs[i].personalDebtUserId = nil }
        r = compute(txs)
        XCTAssertEqual(r[a]?.fairShare, 7000)
        XCTAssertEqual(r[b]?.fairShare, 10000)

        // A member who left: marks fall back to the split; their debt to the
        // account is still reported (is_member = false).
        txs.append(tx("e5", user: b, account: s, .expense, 12, personal: b))
        r = compute(txs, members: [a])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[a]?.fairShare, 17000, "fair_share = total_expenses")
        XCTAssertEqual(r[a]?.personalShare, 0)
        pd = SettlementCalculator.personalDebts(sharedAccountId: s, transactions: txs, memberUserIds: [a])
        let former = pd.first { $0.userId == b }
        XCTAssertEqual(former?.isMember, false)
        XCTAssertEqual(former?.expenses, 3700)
    }

    /// The contract's B4 example decoded from the server equals the local
    /// computation over the same rows — the integrity check stays quiet.
    func test_serverV2_matchesLocal_noMismatch() throws {
        var txs = autoExpense("e1", payer: a, card: ca, 100)
        txs += autoExpense("e2", payer: b, card: cb, 30, personal: b)
        txs += autoExpense("e3", payer: a, card: ca, 40, personal: b)
        txs.append(tx("e4", user: b, account: s, .expense, 25, personal: b))
        txs += repayment("r1", by: b, card: cb, 10)

        let json = """
        {"version": 2, "account_id": "\(s)", "currency": "rub", "total_expenses": 17000, "tx_count": 3,
         "balances": [{"user_id": "\(a)", "contributed": 14000, "fair_share": 5000, "personal_share": 0},
                      {"user_id": "\(b)", "contributed": 3000, "fair_share": 12000, "personal_share": 7000}],
         "payers": {}, "personal_debts": [
           {"user_id": "\(a)", "owed": 0, "expenses": 0, "repaid": 0, "is_member": true},
           {"user_id": "\(b)", "owed": 1500, "expenses": 2500, "repaid": 1000, "is_member": true}]}
        """
        let server = try JSONDecoder().decode(ServerSettlement.self, from: Data(json.utf8))
        let local = SettlementCalculator.compute(
            sharedAccountId: s, transactions: txs, memberUserIds: [a, b],
            personalAccountsByUser: [a: [ca], b: [cb]],
            period: DateInterval(start: .distantPast, end: .distantFuture)
        )
        XCTAssertNil(SettlementViewModel.integrityMismatch(server: server.memberBalances, local: local))
        XCTAssertEqual(local.map(\.personalShare), server.memberBalances.map(\.personalShare))

        let localDebts = SettlementCalculator.personalDebts(sharedAccountId: s, transactions: txs, memberUserIds: [a, b])
        XCTAssertEqual(SettlementViewModel.personalDebts(server: server, local: []), localDebts)
    }

    /// Without marks v2 is v1: the same balances as before the feature.
    func test_noMarks_isV1() {
        var txs = autoExpense("e1", payer: a, card: ca, 101)
        txs += autoExpense("e2", payer: b, card: cb, 33)
        let r = compute(txs)
        XCTAssertEqual(r.values.map(\.personalShare), [0, 0])
        XCTAssertEqual(r.values.map(\.fairShare).reduce(0, +), 13400)
        XCTAssertEqual(SettlementCalculator.personalDebts(sharedAccountId: s, transactions: txs, memberUserIds: [a, b]).map(\.owed), [0, 0])
    }

    /// A v1 server can't know marks: the local personal debts are shown.
    func test_v1Server_fallsBackToLocalPersonalDebts() {
        let v1 = ServerSettlement(version: 1, totalExpenses: 0, balances: [], payers: [:])
        let local = [SettlementCalculator.PersonalDebt(userId: b, expenses: 100, repaid: 0, isMember: true)]
        XCTAssertEqual(SettlementViewModel.personalDebts(server: v1, local: local), local)
    }
}
