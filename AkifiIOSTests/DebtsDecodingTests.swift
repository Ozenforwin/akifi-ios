import XCTest
@testable import AkifiIOS

/// Contract §A8 / §B4 / §C1: tolerant decoding of account types, the
/// `debts` row, `debts_summary`, `personal_debt_user_id` and settlement v2;
/// the exact request bodies of the new write paths.
final class DebtsDecodingTests: XCTestCase {

    /// One `accounts` row as JSON; `type` is the raw JSON of `account_type`
    /// (nil = column missing).
    private func account(json type: String?) -> String {
        let typeField = type.map { ", \"account_type\": \($0)" } ?? ""
        return "{\"id\": \"a-\(UUID().uuidString.prefix(4))\", \"user_id\": \"u1\", \"name\": \"N\", \"icon\": \"💳\", "
            + "\"color\": \"#000000\", \"initial_balance\": 10, \"currency\": \"rub\"\(typeField)}"
    }

    // MARK: - AccountType

    func test_accountType_debtDecodes() throws {
        let acc = try JSONDecoder().decode(Account.self, from: Data(account(json: #""debt""#).utf8))
        XCTAssertEqual(acc.accountType, .debt)
        XCTAssertFalse(acc.isMoneyAccount)
        XCTAssertTrue(acc.isDebtAccount)
    }

    /// C1: one unknown type must never fail the whole accounts list.
    func test_unknownAccountType_doesNotFailTheList() throws {
        let json = "[\(account(json: #""checking""#)), \(account(json: #""credit_line_2030""#)), \(account(json: #""debt""#)), \(account(json: nil)), \(account(json: "42"))]"
        let list = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.accountType), [.checking, .unsupported, .debt, .checking, .unsupported])
        XCTAssertEqual(list.filter(\.isMoneyAccount).count, 2, "unsupported and debt are not money")
        XCTAssertTrue(UnknownAccountTypeLog.loggedValues.contains("credit_line_2030"))
    }

    func test_unknownAccountType_isLoggedOnce() {
        let raw = "zzz_\(UUID().uuidString)"
        _ = AccountType.tolerant(raw)
        _ = AccountType.tolerant(raw)
        XCTAssertEqual(UnknownAccountTypeLog.loggedValues.filter { $0 == raw }.count, 1)
    }

    func test_accountType_isMoneyCoversEveryCase() {
        let money = AccountType.allCases.filter(\.isMoney)
        XCTAssertEqual(Set(money), [.checking, .savings, .cash, .deposit, .investment])
    }

    /// The offline cache round-trips a debt account (and an unsupported one).
    func test_accountCache_roundTrip() throws {
        let debt = Account(id: "d1", userId: "u1", name: "Маша", icon: "👤", color: "#F59E0B",
                           initialBalance: 0, currency: "rub", accountType: .debt)
        let data = try PersistenceManager.makeEncoder().encode([debt])
        let back = try PersistenceManager.makeDecoder().decode([Account].self, from: data)
        XCTAssertEqual(back.first?.accountType, .debt)
    }

    // MARK: - debts / debts_summary

    func test_debtRow_decodes() throws {
        let json = #"{"account_id": "d1", "user_id": "u1", "counterparty_name": "Маша", "counterparty_contact": null, "due_date": "2026-12-31", "remind": true, "note": "на ремонт", "closed_at": null, "created_at": "2026-11-28T09:10:00+00:00", "updated_at": "2026-11-28T09:10:00+00:00"}"#
        let debt = try JSONDecoder().decode(Debt.self, from: Data(json.utf8))
        XCTAssertEqual(debt.id, "d1")
        XCTAssertEqual(debt.dueDate, "2026-12-31")
        XCTAssertTrue(debt.remind)
        XCTAssertFalse(debt.isClosed)
    }

    /// The contract's A4 example, verbatim (plus an unknown key).
    func test_summary_contractExample() throws {
        let summary = try JSONDecoder().decode(DebtsSummary.self, from: Data(Self.contractSummary.utf8))
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.today, "2026-11-28")
        XCTAssertEqual(summary.debts.count, 2)
        let masha = summary.debts[0]
        XCTAssertEqual(masha.balance, 30000)
        XCTAssertEqual(masha.direction, .owedToMe)
        XCTAssertEqual(masha.dueDate, "2026-12-31")
        XCTAssertTrue(masha.remind)
        XCTAssertEqual(masha.txCount, 2)
        XCTAssertEqual(summary.debts[1].balance, -69945)
        XCTAssertEqual(summary.debts[1].direction, .iOwe)
        XCTAssertEqual(summary.totals, [DebtsSummary.Total(currency: "RUB", owedToMe: 30000, iOwe: 69945, openCount: 2)])
    }

    /// Future versions only add keys; a malformed row drops alone.
    func test_summary_isTolerant() throws {
        let json = #"""
        {"version": 7, "today": "2026-11-28", "new_top_level": {"x": 1},
         "debts": [
           {"account_id": "a", "balance": "1500", "currency": "usd", "direction": "something_new", "new_key": [1]},
           {"balance": 1},
           {"account_id": "b", "name": "Петя", "balance": -200, "has_details": false}
         ]}
        """#
        let summary = try JSONDecoder().decode(DebtsSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.version, 7)
        XCTAssertEqual(summary.debts.map(\.accountId), ["a", "b"], "the row without account_id is dropped alone")
        XCTAssertEqual(summary.debts[0].balance, 1500, "numeric string accepted")
        XCTAssertEqual(summary.debts[0].currency, "USD")
        XCTAssertEqual(summary.debts[0].direction, .owedToMe, "unknown direction → from the balance")
        XCTAssertEqual(summary.debts[1].counterpartyName, "Петя", "no details → the account name")
        XCTAssertFalse(summary.debts[1].hasDetails)
        XCTAssertEqual(summary.totals, [], "missing totals → empty")
    }

    // MARK: - transactions.personal_debt_user_id

    func test_transaction_personalDebt_optional() throws {
        let base = #"{"id": "t1", "user_id": "u1", "account_id": "s", "amount": 25, "amount_native": 25, "type": "expense", "date": "2026-11-28T10:00:00""#
        let old = try JSONDecoder().decode(Transaction.self, from: Data((base + "}").utf8))
        XCTAssertNil(old.personalDebtUserId, "a pre-1.6 row decodes as not personal")
        let marked = try JSONDecoder().decode(Transaction.self, from: Data((base + #", "personal_debt_user_id": "BBBB-1"}"#).utf8))
        XCTAssertEqual(marked.personalDebtUserId, "bbbb-1")
        // Cache round-trip keeps it.
        let back = try PersistenceManager.makeDecoder().decode(Transaction.self, from: PersistenceManager.makeEncoder().encode(marked))
        XCTAssertEqual(back.personalDebtUserId, "bbbb-1")
    }

    private func keys(_ value: some Encodable, queue: Bool = false) throws -> [String: Any] {
        let encoder = queue ? PersistenceManager.makeEncoder() : JSONEncoder()
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] ?? [:]
    }

    private func input(personal: String?, source: String? = nil, group: String? = nil, type: String = "expense") -> CreateTransactionInput {
        CreateTransactionInput(
            id: "x1", user_id: "u1", account_id: "shared", amount: 25, currency: "RUB",
            type: type, date: "2026-11-28T10:00:00", description: nil, category_id: nil,
            merchant_name: nil, transfer_group_id: group, payment_source_account_id: source,
            personal_debt_user_id: personal
        )
    }

    /// A plain write never carries the 1.6 column (pre-1.6 server safe).
    func test_createInput_personalOnlyWhenSet() throws {
        XCTAssertNil(try keys(input(personal: nil))["personal_debt_user_id"])
        XCTAssertEqual(try keys(input(personal: "me"))["personal_debt_user_id"] as? String, "me")
        // Offline queue keeps it.
        let queued = try PersistenceManager.makeDecoder().decode(
            CreateTransactionInput.self, from: PersistenceManager.makeEncoder().encode(input(personal: "me"))
        )
        XCTAssertEqual(queued.personal_debt_user_id, "me")
        XCTAssertEqual(queued.withClientId().personal_debt_user_id, "me")
    }

    /// «Оплачено с»: 15 keys with the mark (new overload), 14 without (old).
    func test_autoTransferParams_15keysOnlyWithMark() throws {
        let plain = try keys(CreateExpenseWithAutoTransferParams(input: input(personal: nil, source: "card")))
        XCTAssertEqual(plain.count, 14)
        XCTAssertNil(plain["p_personal_debt_user_id"])
        let marked = try keys(CreateExpenseWithAutoTransferParams(input: input(personal: "bbbb", source: "card")))
        XCTAssertEqual(marked.count, 15)
        XCTAssertEqual(marked["p_personal_debt_user_id"] as? String, "bbbb")
    }

    func test_updateInput_personalMarkEncoding() throws {
        let untouched = UpdateTransactionInput(description: "x")
        XCTAssertNil(try keys(untouched)["personal_debt_user_id"], "not sent unless changed")

        let clear = UpdateTransactionInput(description: "x", personal_debt_user_id: nil, updatesPersonalDebt: true)
        let clearKeys = try keys(clear)
        XCTAssertTrue(clearKeys.keys.contains("personal_debt_user_id"))
        XCTAssertTrue(clearKeys["personal_debt_user_id"] is NSNull, "null clears the mark")

        // The auto-transfer RPC path sends the mark as its own PATCH.
        let rpc = UpdateTransactionInput(useAutoTransferUpdate: true, personal_debt_user_id: "m", updatesPersonalDebt: true)
        XCTAssertNil(try keys(rpc)["personal_debt_user_id"])

        // Survives the offline queue, flag included.
        let queued = try PersistenceManager.makeDecoder().decode(
            UpdateTransactionInput.self, from: PersistenceManager.makeEncoder().encode(rpc)
        )
        XCTAssertTrue(queued.updatesPersonalDebt)
        XCTAssertEqual(queued.personal_debt_user_id, "m")
        XCTAssertTrue(queued.useAutoTransferUpdate)
    }

    func test_personalDebtPatch_alwaysEmitsKey() throws {
        let body = try keys(PersonalDebtPatch(personal_debt_user_id: nil))
        XCTAssertEqual(body.count, 1)
        XCTAssertTrue(body["personal_debt_user_id"] is NSNull)
    }

    func test_offlinePlaceholders_carryMark() {
        let direct = Transaction.placeholder(for: input(personal: "me"), nowISO: "2026-11-28T10:00:00Z")
        XCTAssertEqual(direct.personalDebtUserId, "me")
        let triplet = Transaction.placeholderTriplet(for: input(personal: "me", source: "card"), nowISO: "2026-11-28T10:00:00Z")
        XCTAssertEqual(triplet[0].personalDebtUserId, "me", "the main expense")
        XCTAssertNil(triplet[1].personalDebtUserId, "transfer-out leg")
        XCTAssertNil(triplet[2].personalDebtUserId, "transfer-in leg")
        let edited = direct.applying(UpdateTransactionInput(personal_debt_user_id: nil, updatesPersonalDebt: true))
        XCTAssertNil(edited.personalDebtUserId)
        XCTAssertEqual(direct.applying(UpdateTransactionInput(description: "y")).personalDebtUserId, "me")
    }

    // MARK: - create_debt / PATCH bodies

    func test_createDebtParams_sendsAll10Keys() throws {
        let params = CreateDebtParams.make(accountId: "d1", name: "  Маша ", currency: "RUB", contact: " ", dueDate: nil, remind: true, note: nil)
        let body = try keys(params)
        XCTAssertEqual(body.count, 10)
        XCTAssertEqual(body["p_counterparty_name"] as? String, "Маша")
        XCTAssertEqual(body["p_currency"] as? String, "rub")
        XCTAssertTrue(body["p_counterparty_contact"] is NSNull, "blank → null")
        XCTAssertTrue(body["p_due_date"] is NSNull)
        XCTAssertEqual(body["p_remind"] as? Bool, false, "a reminder needs a due date")
    }

    func test_detailsPatch_nullsExplicit() throws {
        let body = try keys(DebtDetailsPatch(name: "Маша", contact: nil, dueDate: "2026-12-31", remind: true, note: ""))
        XCTAssertEqual(body.count, 5)
        XCTAssertTrue(body["note"] is NSNull)
        XCTAssertEqual(body["remind"] as? Bool, true)
    }

    // MARK: - Settlement v1 / v2

    func test_serverSettlement_v1StillDecodes() throws {
        let json = #"{"version": 1, "account_id": "s", "currency": "rub", "total_expenses": 10000, "tx_count": 1, "balances": [{"user_id": "AAAA", "contributed": 10000, "fair_share": 5000}], "payers": {"e1": "aaaa"}}"#
        let s = try JSONDecoder().decode(ServerSettlement.self, from: Data(json.utf8))
        XCTAssertEqual(s.balances.first?.personalShare, 0)
        XCTAssertEqual(s.personalDebts, [])
        XCTAssertEqual(s.memberBalances.first?.userId, "aaaa")
    }

    /// The contract's B4 example.
    func test_serverSettlement_v2ContractExample() throws {
        let s = try JSONDecoder().decode(ServerSettlement.self, from: Data(Self.contractSettlementV2.utf8))
        XCTAssertEqual(s.version, 2)
        let b = s.memberBalances.first { $0.userId == "bbbb" }
        XCTAssertEqual(b?.personalShare, 7000)
        XCTAssertEqual(b?.delta, -9000, "B owes A 90 ₽")
        let debt = s.personalDebts.first { $0.userId == "bbbb" }
        XCTAssertEqual(debt?.owed, 1500, "B owes the account 15 ₽")
        XCTAssertEqual(debt?.expenses, 2500)
        XCTAssertEqual(debt?.repaid, 1000)
        XCTAssertEqual(debt?.isMember, true)
    }

    // MARK: - Fixtures

    static let contractSummary = #"""
    {
      "version": 1,
      "today": "2026-11-28",
      "something_from_the_future": true,
      "debts": [
        {"account_id": "6f1c2d9e", "name": "Маша", "icon": "person.crop.circle", "color": "#F59E0B", "currency": "RUB",
         "balance": 30000, "direction": "owed_to_me", "counterparty_name": "Маша", "counterparty_contact": "+7 900 000-00-00",
         "due_date": "2026-12-31", "remind": true, "note": "на ремонт", "closed_at": null, "is_closed": false,
         "is_overdue": false, "has_details": true, "tx_count": 2, "last_movement_at": "2026-11-28T09:12:00+00:00",
         "created_at": "2026-11-28T09:10:00.123+00:00"},
        {"account_id": "0b7e", "name": "Петя", "icon": "person.fill", "color": "#10B981", "currency": "RUB",
         "balance": -69945, "direction": "i_owe", "counterparty_name": "Петя", "counterparty_contact": null,
         "due_date": null, "remind": false, "note": null, "closed_at": null, "is_closed": false, "is_overdue": false,
         "has_details": true, "tx_count": 2, "last_movement_at": "2026-11-28T09:20:00+00:00",
         "created_at": "2026-11-28T09:15:00+00:00"}
      ],
      "totals": [{"currency": "RUB", "owed_to_me": 30000, "i_owe": 69945, "open_count": 2}]
    }
    """#

    static let contractSettlementV2 = #"""
    {
      "version": 2, "account_id": "fecd", "currency": "rub", "total_expenses": 17000, "tx_count": 3,
      "balances": [
        {"user_id": "aaaa", "contributed": 14000, "fair_share": 5000, "personal_share": 0},
        {"user_id": "bbbb", "contributed": 3000, "fair_share": 12000, "personal_share": 7000}
      ],
      "payers": {"e1": "aaaa"},
      "personal_debts": [
        {"user_id": "aaaa", "owed": 0, "expenses": 0, "repaid": 0, "is_member": true},
        {"user_id": "bbbb", "owed": 1500, "expenses": 2500, "repaid": 1000, "is_member": true}
      ]
    }
    """#
}
