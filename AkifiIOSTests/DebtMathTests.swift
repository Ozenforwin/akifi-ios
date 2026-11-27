import XCTest
@testable import AkifiIOS

/// Contract §A1/§A4/§A5: balance, direction, totals, overdue, merge of the
/// server summary with local accounts, and the four actions' legs.
final class DebtMathTests: XCTestCase {

    static func debt(_ id: String, _ name: String, currency: String = "rub", initial: Int64 = 0, created: String? = nil) -> Account {
        Account(id: id, userId: "me", name: name, icon: "👤", color: "#F59E0B", initialBalance: initial,
                currency: currency, accountType: .debt, createdAt: created)
    }

    static func leg(_ id: String, account: String, _ type: TransactionType, _ minor: Int64, group: String = "g", date: String = "2026-11-28T10:00:00") -> Transaction {
        Transaction(id: id, userId: "me", accountId: account, amount: minor, currency: "RUB", description: nil,
                    categoryId: nil, type: type, date: String(date.prefix(10)), rawDateTime: date, merchantName: nil,
                    merchantFuzzy: nil, transferGroupId: group, status: nil, createdAt: nil, updatedAt: nil)
    }

    // MARK: - Balance (same formula as debts_summary)

    /// Маша: lent 500, got 200 back → owes me 300. Петя: borrowed 1 000,
    /// repaid 300.55 → I owe 699.45 (the contract's −69945).
    func test_balance_matchesContractExample() {
        let masha = Self.debt("m", "Маша")
        let petya = Self.debt("p", "Петя")
        let txs = [
            Self.leg("1", account: "m", .income, 500_00),
            Self.leg("2", account: "m", .expense, 200_00),
            Self.leg("3", account: "p", .expense, 1_000_00),
            Self.leg("4", account: "p", .income, 300_55),
            Self.leg("5", account: "card", .expense, 500_00),
        ]
        XCTAssertEqual(DebtMath.balance(of: masha, transactions: txs), 30000)
        XCTAssertEqual(DebtMath.balance(of: petya, transactions: txs), -69945)
        XCTAssertEqual(DebtDirection(balance: 30000), .owedToMe)
        XCTAssertEqual(DebtDirection(balance: -69945), .iOwe)
        XCTAssertEqual(DebtDirection(balance: 0), .settled)
        XCTAssertEqual(DebtMath.balance(of: Self.debt("x", "X", initial: 100_00), transactions: []), 100_00, "initial balance counts")
    }

    func test_overdue() {
        XCTAssertTrue(DebtMath.isOverdue(dueDate: "2026-11-27", balance: 1, isClosed: false, today: "2026-11-28"))
        XCTAssertFalse(DebtMath.isOverdue(dueDate: "2026-11-28", balance: 1, isClosed: false, today: "2026-11-28"), "due today is not overdue")
        XCTAssertFalse(DebtMath.isOverdue(dueDate: "2026-11-01", balance: 0, isClosed: false, today: "2026-11-28"), "settled")
        XCTAssertFalse(DebtMath.isOverdue(dueDate: "2026-11-01", balance: 5, isClosed: true, today: "2026-11-28"), "closed")
        XCTAssertFalse(DebtMath.isOverdue(dueDate: nil, balance: 5, isClosed: false, today: "2026-11-28"))
    }

    // MARK: - Merge

    private func summary(_ entries: [DebtsSummary.Entry], today: String = "2026-11-28") -> DebtsSummary {
        DebtsSummary(version: 1, today: today, debts: entries)
    }

    func test_merge_localBalanceUnlessServerIsFresh() {
        let masha = Self.debt("m", "Маша")
        let txs = [Self.leg("1", account: "m", .income, 500_00)]
        let s = summary([DebtsSummary.Entry(accountId: "m", name: "Маша", currency: "RUB", balance: 400_00, dueDate: "2026-12-31", remind: true)])

        let local = DebtMath.merge(summary: s, debtAccounts: [masha], transactions: txs, preferServerBalance: false, today: "2026-11-28")
        XCTAssertEqual(local.first?.balance, 500_00, "own (queued) movements win over an older summary")
        XCTAssertEqual(local.first?.dueDate, "2026-12-31", "details always from the summary")
        XCTAssertTrue(local.first?.remind == true)

        let server = DebtMath.merge(summary: s, debtAccounts: [masha], transactions: txs, preferServerBalance: true, today: "2026-11-28")
        XCTAssertEqual(server.first?.balance, 400_00)
    }

    func test_merge_unionOfServerAndLocal() {
        let fresh = Self.debt("new", "Новый")
        let s = summary([DebtsSummary.Entry(accountId: "other-device", name: "Оля", currency: "USD", balance: 10_00)])
        let merged = DebtMath.merge(summary: s, debtAccounts: [fresh], transactions: [], preferServerBalance: false, today: "2026-11-28")
        XCTAssertEqual(Set(merged.map(\.accountId)), ["new", "other-device"])
        XCTAssertFalse(merged.first { $0.accountId == "new" }!.hasDetails, "a local-only account has no details yet")
        XCTAssertEqual(merged.first { $0.accountId == "other-device" }?.balance, 10_00)
    }

    func test_merge_overdueUsesServerToday() {
        let a = Self.debt("a", "A")
        let s = summary([DebtsSummary.Entry(accountId: "a", name: "A", currency: "RUB", balance: 1, dueDate: "2026-11-28")], today: "2026-11-29")
        let merged = DebtMath.merge(summary: s, debtAccounts: [a], transactions: [Self.leg("1", account: "a", .income, 100)], preferServerBalance: false, today: "2026-11-28")
        XCTAssertTrue(merged[0].isOverdue, "the server's local day (profile time zone) decides")
    }

    /// Contract order: open first, due date (nulls last), created, id.
    func test_sorting() {
        func e(_ id: String, due: String?, closed: Bool = false, created: String) -> DebtEntry {
            DebtEntry(accountId: id, name: id, icon: nil, color: nil, currency: "RUB", balance: 1, contact: nil,
                      dueDate: due, remind: false, note: nil, closedAt: closed ? "x" : nil, hasDetails: true, isOverdue: false, createdAt: created)
        }
        let sorted = DebtMath.sorted([
            e("closed", due: "2026-01-01", closed: true, created: "1"),
            e("noDue", due: nil, created: "1"),
            e("late", due: "2026-12-31", created: "1"),
            e("early", due: "2026-12-01", created: "2"),
            e("earlyOld", due: "2026-12-01", created: "1"),
        ])
        XCTAssertEqual(sorted.map(\.accountId), ["earlyOld", "early", "late", "noDue", "closed"])
    }

    func test_totals_openOnlyPerCurrency() {
        func e(_ id: String, _ ccy: String, _ bal: Int64, closed: Bool = false) -> DebtEntry {
            DebtEntry(accountId: id, name: id, icon: nil, color: nil, currency: ccy, balance: bal, contact: nil, dueDate: nil,
                      remind: false, note: nil, closedAt: closed ? "x" : nil, hasDetails: true, isOverdue: false, createdAt: nil)
        }
        let totals = DebtMath.totals([e("a", "RUB", 300_00), e("b", "RUB", -699_45), e("c", "USD", 50_00), e("d", "RUB", 1_000_00, closed: true), e("z", "RUB", 0)])
        XCTAssertEqual(totals, [
            DebtsSummary.Total(currency: "RUB", owedToMe: 300_00, iOwe: 699_45, openCount: 3),
            DebtsSummary.Total(currency: "USD", owedToMe: 50_00, iOwe: 0, openCount: 1),
        ])
        let one = DebtMath.convertedTotals(totals, to: "RUB", rates: ["USD": 1, "RUB": 100])
        XCTAssertEqual(one.owedToMe, 300_00 + 5_000_00)
        XCTAssertEqual(one.iOwe, 699_45)
        XCTAssertEqual(one.missing, [])
        let noRate = DebtMath.convertedTotals(totals, to: "RUB", rates: ["RUB": 100])
        XCTAssertEqual(noRate.missing, ["USD"], "never summed 1:1")
        XCTAssertEqual(noRate.owedToMe, 300_00)
    }

    func test_movements_newestFirst() {
        let txs = [
            Self.leg("old", account: "m", .income, 1, date: "2026-11-01T10:00:00"),
            Self.leg("new", account: "m", .expense, 1, date: "2026-11-20T10:00:00"),
            Self.leg("card", account: "card", .expense, 1, date: "2026-11-25T10:00:00"),
        ]
        XCTAssertEqual(DebtMath.movements(accountId: "m", transactions: txs).map(\.id), ["new", "old"])
    }
}

final class DebtActionTests: XCTestCase {

    func test_direction() {
        XCTAssertTrue(DebtAction.lend.movesIntoDebt)
        XCTAssertTrue(DebtAction.repaid.movesIntoDebt)
        XCTAssertFalse(DebtAction.gotRepaid.movesIntoDebt)
        XCTAssertFalse(DebtAction.borrow.movesIntoDebt)
        XCTAssertEqual(DebtAction.lend.balance(after: 500_00, from: 0), 500_00)
        XCTAssertEqual(DebtAction.gotRepaid.balance(after: 200_00, from: 500_00), 300_00)
        XCTAssertEqual(DebtAction.borrow.balance(after: 1_000_00, from: 0), -1_000_00)
        XCTAssertEqual(DebtAction.repaid.balance(after: 300_55, from: -1_000_00), -699_45)
    }

    /// Repayments default to |balance| when it points their way.
    func test_defaultAmounts() {
        XCTAssertEqual(DebtAction.gotRepaid.defaultAmount(balance: 300_00), 300_00)
        XCTAssertNil(DebtAction.gotRepaid.defaultAmount(balance: -300_00))
        XCTAssertEqual(DebtAction.repaid.defaultAmount(balance: -699_45), 699_45)
        XCTAssertNil(DebtAction.repaid.defaultAmount(balance: 100))
        XCTAssertNil(DebtAction.lend.defaultAmount(balance: 100))
        XCTAssertNil(DebtAction.borrow.defaultAmount(balance: -100))
    }

    /// Partial is fine, exact settles, more flips (confirm first).
    func test_partialExactOver() {
        XCTAssertFalse(DebtAction.gotRepaid.flipsSign(amount: 100_00, balance: 300_00))
        XCTAssertFalse(DebtAction.gotRepaid.settles(amount: 100_00, balance: 300_00))
        XCTAssertTrue(DebtAction.gotRepaid.settles(amount: 300_00, balance: 300_00))
        XCTAssertFalse(DebtAction.gotRepaid.flipsSign(amount: 300_00, balance: 300_00))
        XCTAssertTrue(DebtAction.gotRepaid.flipsSign(amount: 400_00, balance: 300_00))
        XCTAssertTrue(DebtAction.repaid.flipsSign(amount: 800_00, balance: -699_45))
        XCTAssertTrue(DebtAction.gotRepaid.flipsSign(amount: 1, balance: 0), "a «repayment» on a settled debt opens the other side")
        XCTAssertFalse(DebtAction.lend.flipsSign(amount: 10_000_00, balance: -100), "lending more is not a repayment")
    }
}

final class DebtTransferBuilderTests: XCTestCase {

    let debtRub = DebtMathTests.debt("debt", "Маша")
    let debtUsd = DebtMathTests.debt("debt-usd", "John", currency: "usd")
    let cardRub = Account(id: "card", userId: "me", name: "Карта", icon: "💳", color: "#000", initialBalance: 0, currency: "rub")
    let cardUsd = Account(id: "card-usd", userId: "me", name: "Bybit", icon: "💳", color: "#000", initialBalance: 0, currency: "usd")
    let rates: [String: Double] = ["USD": 1, "RUB": 100]

    private func legs(_ action: DebtAction, amount: Decimal = 3_000, entry: Currency = .rub, debt: Account? = nil, real: Account? = nil) throws -> DebtTransferBuilder.Legs {
        try DebtTransferBuilder.legs(
            action: action, amount: amount, entryCurrency: entry, debtAccount: debt ?? debtRub,
            realAccount: real ?? cardRub, rates: rates, userId: "me", date: "2026-11-28T10:00:00",
            counterpartyName: "Маша", comment: "на ремонт", groupId: "grp"
        )
    }

    /// The table in contract §A5, leg by leg.
    func test_fourActions_legShapes() throws {
        let table: [(DebtAction, expenseOn: String, incomeOn: String)] = [
            (.lend, "card", "debt"),
            (.gotRepaid, "debt", "card"),
            (.borrow, "debt", "card"),
            (.repaid, "card", "debt"),
        ]
        for (action, expenseOn, incomeOn) in table {
            let l = try legs(action)
            XCTAssertEqual(l.expense.account_id, expenseOn, "\(action)")
            XCTAssertEqual(l.income.account_id, incomeOn, "\(action)")
            XCTAssertEqual(l.expense.type, "expense")
            XCTAssertEqual(l.income.type, "income")
            for leg in [l.expense, l.income] {
                XCTAssertEqual(leg.transfer_group_id, "grp")
                XCTAssertNil(leg.category_id)
                XCTAssertNil(leg.personal_debt_user_id)
                XCTAssertNil(leg.payment_source_account_id, "never an auto-transfer")
                XCTAssertEqual(leg.user_id, "me")
                XCTAssertEqual(leg.date, "2026-11-28T10:00:00")
                XCTAssertEqual(leg.merchant_name, "Маша")
                XCTAssertEqual(leg.amount, 3_000)
                XCTAssertEqual(leg.amount_native, 3_000)
                XCTAssertEqual(leg.currency, "RUB")
                XCTAssertNil(leg.foreign_amount)
                XCTAssertFalse(leg.routesToAutoTransferRPC)
                XCTAssertTrue(leg.description?.contains("Маша") == true)
                XCTAssertTrue(leg.description?.contains("на ремонт") == true)
            }
        }
    }

    /// ADR-001: each leg in its own account's currency; the converted one
    /// keeps the entry in foreign_*.
    func test_crossCurrency_eachLegInItsCurrency() throws {
        let l = try legs(.lend, amount: 100, entry: .usd, debt: debtRub, real: cardUsd)
        XCTAssertEqual(l.expense.account_id, "card-usd")
        XCTAssertEqual(l.expense.amount_native, 100)
        XCTAssertEqual(l.expense.currency, "USD")
        XCTAssertNil(l.expense.foreign_amount)
        XCTAssertEqual(l.income.account_id, "debt")
        XCTAssertEqual(l.income.amount_native, 10_000)
        XCTAssertEqual(l.income.amount, 10_000)
        XCTAssertEqual(l.income.currency, "RUB")
        XCTAssertEqual(l.income.foreign_amount, 100)
        XCTAssertEqual(l.income.foreign_currency, "USD")
    }

    func test_missingQuote_throwsBeforeAnyLeg() {
        XCTAssertThrowsError(try DebtTransferBuilder.legs(
            action: .lend, amount: 100, entryCurrency: .usd, debtAccount: debtRub, realAccount: cardUsd,
            rates: [:], userId: "me", date: "2026-11-28T10:00:00", counterpartyName: "Маша", comment: nil
        )) { XCTAssertTrue($0 is MissingFXRateError) }
    }

    func test_refusesNonMoneyRealAccountAndBadInput() {
        XCTAssertThrowsError(try legs(.lend, real: debtUsd)) { XCTAssertEqual($0 as? DebtTransferError, .notAMoneyAccount) }
        XCTAssertThrowsError(try legs(.lend, debt: cardUsd)) { XCTAssertEqual($0 as? DebtTransferError, .notADebtAccount) }
        XCTAssertThrowsError(try legs(.lend, amount: 0)) { XCTAssertEqual($0 as? DebtTransferError, .invalidAmount) }
    }

    /// B5: income leg on the shared account carries `personal_debt_user_id = me`.
    func test_personalRepaymentLegs() throws {
        let shared = Account(id: "shared", userId: "owner", name: "Семейный", icon: "👪", color: "#000", initialBalance: 0, currency: "rub")
        let l = try DebtTransferBuilder.personalRepaymentLegs(
            amount: 15, entryCurrency: .rub, sharedAccount: shared, fromAccount: cardRub,
            rates: rates, userId: "me", date: "2026-11-28T10:00:00", groupId: "g"
        )
        XCTAssertEqual(l.expense.account_id, "card")
        XCTAssertNil(l.expense.personal_debt_user_id)
        XCTAssertEqual(l.income.account_id, "shared")
        XCTAssertEqual(l.income.personal_debt_user_id, "me")
        XCTAssertEqual(l.income.type, "income")
        XCTAssertEqual(l.income.transfer_group_id, "g")
        XCTAssertEqual(l.expense.transfer_group_id, "g")
        XCTAssertFalse(l.income.routesToAutoTransferRPC)
        XCTAssertThrowsError(try DebtTransferBuilder.personalRepaymentLegs(
            amount: 15, entryCurrency: .rub, sharedAccount: shared, fromAccount: shared,
            rates: rates, userId: "me", date: "x"
        ))
    }

    func test_debtAccountOfLeg() {
        let accounts = [debtRub, cardRub]
        let lookup: (String?) -> Account? = { id in accounts.first { $0.id == id } }
        let txs = [
            DebtMathTests.leg("out", account: "card", .expense, 1, group: "g1"),
            DebtMathTests.leg("in", account: "debt", .income, 1, group: "g1"),
            DebtMathTests.leg("plain", account: "card", .expense, 1, group: "g2"),
            DebtMathTests.leg("plain2", account: "card-2", .income, 1, group: "g2"),
        ]
        XCTAssertEqual(DebtTransferBuilder.debtAccount(of: txs[0], accounts: lookup, transactions: txs)?.id, "debt", "the card leg")
        XCTAssertEqual(DebtTransferBuilder.debtAccount(of: txs[1], accounts: lookup, transactions: txs)?.id, "debt", "the debt leg")
        XCTAssertNil(DebtTransferBuilder.debtAccount(of: txs[2], accounts: lookup, transactions: txs), "an ordinary transfer")
    }

    func test_editHelpers() {
        XCTAssertEqual(DebtMovementForm.comment(from: "Долг: Маша · на ремонт"), "на ремонт")
        XCTAssertEqual(DebtMovementForm.comment(from: "Долг: Маша"), "")
        let leg = DebtMathTests.leg("in", account: "debt", .income, 1)
        XCTAssertEqual(DebtMovementForm.direction(of: leg, debtAccountId: "debt"), .lend)
        let cardLeg = DebtMathTests.leg("out", account: "card", .income, 1)
        XCTAssertEqual(DebtMovementForm.direction(of: cardLeg, debtAccountId: "debt"), .borrow)
    }
}

/// The store end to end with a fake server and an offline DataStore: no
/// network is touched.
@MainActor
final class DebtsStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DebtsStore-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private func makeStore() -> (DataStore, CurrencyManager) {
        let store = DataStore(cache: PersistenceManager(directory: tempDir))
        store.isConnectedProvider = { false }
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.apply(FXRateSnapshot.fromNetwork(["USD": 1, "RUB": 100], at: Date()))
        store.currencyManager = cm
        store.allAccounts = [DebtExclusionTests.card]
        store.rebuildCaches()
        return (store, cm)
    }

    private func makeDebts(summary: DebtsSummary? = nil, created: Box<[CreateDebtParams]> = Box([])) -> DebtsStore {
        let debts = DebtsStore()
        debts.remote = DebtsStore.Remote(
            fetchSummary: {
                if let summary { return summary }
                throw URLError(.notConnectedToInternet)
            },
            create: { params in created.value.append(params); return params.p_account_id },
            updateDetails: { _, _ in },
            rename: { _, _ in },
            setClosed: { _, _ in },
            delete: { _ in },
            currentUserId: { "me" }
        )
        debts.reminders = DebtReminderScheduler(pendingIdentifiers: { [] }, schedule: { _ in }, cancel: { _ in })
        return debts
    }

    /// New debt + «Дал в долг» offline: the legs are queued like any
    /// manual transfer and the balance moves at once.
    func test_createThenLend_offlineQueued() async throws {
        let (store, cm) = makeStore()
        let created = Box<[CreateDebtParams]>([])
        let debts = makeDebts(created: created)

        let account = try await debts.createDebt(
            DebtsStore.NewDebt(name: "Маша", currency: "RUB", contact: nil, dueDate: "2026-12-31", remind: true, note: nil),
            dataStore: store
        )
        XCTAssertEqual(created.value.count, 1)
        XCTAssertEqual(account.accountType, .debt)
        XCTAssertNil(store.accounts.first { $0.id == account.id }, "never in the money accounts")
        XCTAssertEqual(debts.entries(dataStore: store).first?.balance, 0, "settled until the first movement")
        XCTAssertEqual(debts.entries(dataStore: store).first?.dueDate, "2026-12-31", "optimistic details")

        try await debts.record(.lend, amount: 3_000, entryCurrency: .rub, debtAccount: account,
                               realAccount: DebtExclusionTests.card, counterpartyName: "Маша",
                               date: Date(), comment: nil, dataStore: store, currencyManager: cm)

        XCTAssertEqual(store.offlineQueue.pendingCount, 2, "both legs through the offline queue")
        let entry = debts.entries(dataStore: store).first
        XCTAssertEqual(entry?.balance, 3_000_00)
        XCTAssertEqual(entry?.direction, .owedToMe)
        XCTAssertEqual(store.balance(for: DebtExclusionTests.card), 10_000_00 - 3_000_00)
        let legs = store.transactions.filter { $0.transferGroupId != nil }
        XCTAssertEqual(Set(legs.compactMap(\.transferGroupId)).count, 1, "one transfer_group_id")
        XCTAssertTrue(legs.allSatisfy { $0.autoTransferGroupId == nil })
    }

    /// The server balance is used only when newer than every local write.
    func test_serverBalanceOnlyWhenFresh() async throws {
        let (store, cm) = makeStore()
        let masha = DebtExclusionTests.masha
        store.allAccounts.append(masha)
        store.transactions = DebtExclusionTests.lendLegs()
        store.rebuildCaches()
        let debts = makeDebts(summary: DebtsSummary(debts: [
            DebtsSummary.Entry(accountId: masha.id, name: "Маша", currency: "RUB", balance: 2_500_00)
        ]))
        await debts.refresh(dataStore: store)
        XCTAssertFalse(debts.isOffline)
        XCTAssertTrue(debts.prefersServerBalance(store))
        XCTAssertEqual(debts.entry(accountId: masha.id, dataStore: store)?.balance, 2_500_00)

        // A local write makes the summary stale → the local balance.
        _ = try await store.addTransaction(CreateTransactionInput(
            user_id: "me", account_id: masha.id, amount: 100, currency: "RUB", type: "expense",
            date: "2026-11-28T11:00:00", description: nil, category_id: nil, merchant_name: nil,
            transfer_group_id: "g2"
        ))
        XCTAssertFalse(debts.prefersServerBalance(store))
        XCTAssertEqual(debts.entry(accountId: masha.id, dataStore: store)?.balance, 3_000_00 - 100_00)
        _ = cm
    }

    func test_offlineRefresh_keepsLocalNumbers() async {
        let (store, _) = makeStore()
        store.allAccounts.append(DebtExclusionTests.masha)
        store.transactions = DebtExclusionTests.lendLegs()
        store.rebuildCaches()
        let debts = makeDebts(summary: nil)
        await debts.refresh(dataStore: store)
        XCTAssertTrue(debts.isOffline)
        XCTAssertEqual(debts.entries(dataStore: store).first?.balance, 3_000_00)
    }
}
