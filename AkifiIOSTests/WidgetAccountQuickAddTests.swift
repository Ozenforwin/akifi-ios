import XCTest
@testable import AkifiIOS

/// 1.6.0 widgets «Счёт» and «Быстрая запись»: what the snapshot carries
/// (money accounts only, native balances, the eye toggle, «Повторить»), the
/// schema window, the account picker's query, the shared quick-add link
/// builder / parser and what a widget tap opens, the reload policy.
@MainActor
final class WidgetAccountQuickAddTests: XCTestCase {

    // MARK: - Fixtures

    static let me = "u-me"
    static let partner = "u-partner"
    static let cardId = "0a000000-0000-4000-8000-000000000001"
    static let cashId = "0a000000-0000-4000-8000-000000000002"
    static let usdId = "0a000000-0000-4000-8000-000000000003"
    static let familyId = "0a000000-0000-4000-8000-000000000004"
    static let debtId = "0a000000-0000-4000-8000-000000000005"
    static let futureId = "0a000000-0000-4000-8000-000000000006"
    static let cafeId = "0c000000-0000-4000-8000-000000000001"
    static let salaryId = "0c000000-0000-4000-8000-000000000002"

    static let card = Account(id: cardId, userId: me, name: "Тинькофф", icon: "💳", color: "#3B82F6",
                              initialBalance: 10_000_00, isPrimary: true, currency: "rub")
    static let cash = Account(id: cashId, userId: me, name: "Наличные", icon: "💵", color: "#10B981",
                              initialBalance: 2_000_00, currency: "rub", accountType: .cash)
    static let usd = Account(id: usdId, userId: me, name: "ByBit", icon: "🪙", color: "#F59E0B",
                             initialBalance: 500_00, currency: "usd", accountType: .investment)
    /// Owned by the partner → shared with me.
    static let family = Account(id: familyId, userId: partner, name: "Семейный", icon: "👪", color: "not-a-colour",
                                initialBalance: 0, currency: "rub")
    static let masha = Account(id: debtId, userId: me, name: "Маша", icon: "👤", color: "#F43F5E",
                               initialBalance: 0, currency: "rub", accountType: .debt)
    static let future = Account(id: futureId, userId: me, name: "Новый тип", icon: "?", color: "#000",
                                initialBalance: 1_000_00, currency: "rub", accountType: .unsupported)

    static let cafe = AkifiIOS.Category(id: cafeId, userId: me, accountId: nil, name: "Кафе", icon: "☕️",
                                        color: "#000000", type: .expense, isActive: true, createdAt: "2026-01-01T00:00:00Z")
    static let salary = AkifiIOS.Category(id: salaryId, userId: me, accountId: nil, name: "Зарплата", icon: "💼",
                                          color: "#000000", type: .income, isActive: true, createdAt: "2026-01-01T00:00:00Z")

    /// Friday 27 November 2026, midday in every time zone's November.
    static let now = QE.now

    static func tx(
        _ id: String, _ account: String, _ type: TransactionType, _ minor: Int64, raw: String,
        description: String? = nil, category: String? = nil, group: String? = nil, user: String = me,
        foreignAmount: Decimal? = nil, foreignCurrency: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: user, accountId: account, amount: minor, amountNative: minor, currency: "RUB",
            foreignAmount: foreignAmount, foreignCurrency: foreignCurrency, fxRate: nil,
            description: description, categoryId: category, type: type,
            date: String(raw.prefix(10)), rawDateTime: raw, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: group, status: nil, createdAt: raw, updatedAt: nil
        )
    }

    static var transactions: [Transaction] {
        [
            tx("t-coffee", cardId, .expense, 300_00, raw: "2026-11-26T09:00:00", description: "Кофе", category: cafeId),
            tx("t-uber", cardId, .expense, 900_00, raw: "2026-11-25T20:00:00", description: "Uber",
               foreignAmount: 9, foreignCurrency: "USD"),
            tx("t-netflix", usdId, .expense, 12_50, raw: "2026-11-20T08:00:00", description: "Netflix"),
            tx("t-salary", cardId, .income, 50_000_00, raw: "2026-11-15T10:00:00", category: salaryId),
            tx("t-october", cardId, .expense, 1_000_00, raw: "2026-10-30T12:00:00", description: "Книга"),
            // «Дал в долг» Маше: two legs of one group — a debt movement.
            tx("t-lend-out", cardId, .expense, 3_000_00, raw: "2026-11-24T12:00:00", description: "Долг: Маша", group: "g-lend"),
            tx("t-lend-in", debtId, .income, 3_000_00, raw: "2026-11-24T12:00:00", description: "Долг: Маша", group: "g-lend"),
            // Card → cash.
            tx("t-move-out", cardId, .expense, 2_000_00, raw: "2026-11-23T12:00:00", group: "g-move"),
            tx("t-move-in", cashId, .income, 2_000_00, raw: "2026-11-23T12:00:00", group: "g-move"),
            // The partner's row on the shared account: never «my» repeat.
            tx("t-pizza", familyId, .expense, 1_500_00, raw: "2026-11-26T21:00:00", description: "Пицца", user: partner),
        ]
    }

    private var tempDirs: [URL] = []

    override func tearDown() {
        tempDirs.forEach { try? FileManager.default.removeItem(at: $0) }
        tempDirs = []
        super.tearDown()
    }

    private func makeStore() -> DataStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetAQ-\(UUID().uuidString)")
        tempDirs.append(dir)
        let store = DataStore(cache: PersistenceManager(directory: dir))
        store.isConnectedProvider = { false }
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = ["USD": 1, "RUB": 100]
        store.currencyManager = cm
        store.profile = Profile(id: Self.me, email: nil, fullName: nil, avatarUrl: nil, defaultCurrency: "RUB",
                                telegramUserId: nil, telegramChatId: nil, telegramLinkedAt: nil, updatedAt: nil)
        // The card twice: a shared account can arrive twice from the joins.
        store.allAccounts = [Self.card, Self.masha, Self.usd, Self.cash, Self.family, Self.future, Self.card]
        store.categories = [Self.cafe, Self.salary]
        store.transactions = Self.transactions
        store.rebuildCaches()
        return store
    }

    private func build(_ store: DataStore, hidden: Set<String> = []) -> SharedSnapshot {
        SharedSnapshotWriter.buildSnapshot(dataStore: store, currencyManager: store.currencyManager!,
                                           now: Self.now, hiddenBalanceIds: hidden)
    }

    private func item(_ snapshot: SharedSnapshot, _ id: String) throws -> SharedSnapshot.AccountItem {
        try XCTUnwrap(snapshot.accounts?.first { $0.id == id }, "no item for \(id)")
    }

    // MARK: - Snapshot: accounts

    func test_accounts_areMoneyAccountsOnce_inAppOrder() {
        let snapshot = build(makeStore())
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.accounts?.map(\.id), [Self.cardId, Self.usdId, Self.cashId, Self.familyId],
                       "no «Долги» account, no unknown type, the duplicate card once")
        XCTAssertEqual(snapshot.monthKey, "2026-11")
    }

    /// ADR-001: each balance in its OWN currency, via `nativeBalance`.
    func test_balances_areNative() throws {
        let store = makeStore()
        let snapshot = build(store)
        // 10 000 + 50 000 − 300 − 900 − 1 000 (Oct) − 3 000 (lent) − 2 000 (to cash)
        XCTAssertEqual(try item(snapshot, Self.cardId).balance, 52_800_00)
        XCTAssertEqual(try item(snapshot, Self.cashId).balance, 4_000_00)
        // $500 − $12.50 — dollars, NOT the 4 875 ₽ the carousel shows.
        let usd = try item(snapshot, Self.usdId)
        XCTAssertEqual(usd.balance, 487_50)
        XCTAssertEqual(usd.balance, store.nativeBalance(for: Self.usd))
        XCTAssertNotEqual(usd.balance, store.balance(for: Self.usd), "the base-currency cache is not the widget's number")
        XCTAssertEqual(usd.currencyCode, "USD")
        XCTAssertEqual(usd.currencySymbol, "$")
        XCTAssertEqual(usd.currencyDecimals, 2)
        let card = try item(snapshot, Self.cardId)
        XCTAssertEqual(card.currencyCode, "RUB")
        XCTAssertEqual(card.currencySymbol, "₽")
        XCTAssertEqual(card.currencyDecimals, 0)
        // The legacy total is still the base-currency sum of money accounts.
        XCTAssertEqual(snapshot.accountCount, store.accounts.count)
    }

    /// This month only; transfers and debt movements are not cashflow.
    func test_monthFlow_isNative_andSkipsTransfersAndDebts() throws {
        let store = makeStore()
        let snapshot = build(store)
        let card = try item(snapshot, Self.cardId)
        XCTAssertEqual(card.monthIncome, 50_000_00)
        XCTAssertEqual(card.monthExpense, 1_200_00, "coffee + Uber; not October, not the loan, not the move to cash")
        let cash = try item(snapshot, Self.cashId)
        XCTAssertEqual(cash.monthIncome, 0, "money moved in from the card is not income")
        let usd = try item(snapshot, Self.usdId)
        XCTAssertEqual(usd.monthExpense, 12_50, "dollars")

        // Same buckets as the carousel's chips where no FX is involved.
        let base = store.currentMonthFlow(for: Self.card, now: Self.now)
        XCTAssertEqual(base.income, card.monthIncome)
        XCTAssertEqual(base.expense, card.monthExpense)
    }

    func test_flags_primaryShared_andHiddenBalance() throws {
        let snapshot = build(makeStore(), hidden: [Self.cashId])
        let card = try item(snapshot, Self.cardId)
        XCTAssertTrue(card.isPrimary)
        XCTAssertFalse(card.isShared)
        XCTAssertFalse(card.isBalanceHidden)
        XCTAssertTrue(try item(snapshot, Self.familyId).isShared, "someone else's account is shared with me")
        let cash = try item(snapshot, Self.cashId)
        XCTAssertTrue(cash.isBalanceHidden)
        XCTAssertEqual(WidgetMoney.balance(cash), "••••")
        XCTAssertEqual(WidgetMoney.income(cash), "••••")
        XCTAssertEqual(WidgetMoney.expense(cash), "••••")
        XCTAssertEqual(try item(snapshot, Self.familyId).colorHex, "not-a-colour", "stored as is; the widget falls back")
        XCTAssertNil(WidgetPalette.color(hex: "not-a-colour"))
        XCTAssertNotNil(WidgetPalette.color(hex: "#3B82F6"))
        XCTAssertNotNil(WidgetPalette.color(hex: "fff"))
    }

    /// The Home card's eye: the same defaults key the carousel writes.
    func test_hiddenBalances_readsTheCarouselStorage() {
        let defaults = UserDefaults(suiteName: "WidgetAQ-\(UUID().uuidString)")!
        XCTAssertEqual(HiddenBalances.ids(in: defaults), [])
        defaults.set([Self.cashId, Self.cardId], forKey: "akifi-hidden-balances")
        XCTAssertEqual(HiddenBalances.ids(in: defaults), [Self.cashId, Self.cardId])
    }

    // MARK: - Snapshot: «Повторить»

    func test_repeatItems_topThreeOwnEntries_withPrefilledLinks() throws {
        let snapshot = build(makeStore())
        let items = try XCTUnwrap(snapshot.repeatItems)
        XCTAssertEqual(items.map(\.title), ["Кофе", "Uber", "Netflix"], "newest own entries; the partner's pizza and transfers are out")
        XCTAssertTrue(items.allSatisfy { !$0.isIncome })

        let coffee = items[0]
        XCTAssertEqual(coffee.icon, "☕️")
        XCTAssertEqual(coffee.accountName, "Тинькофф")
        XCTAssertTrue(coffee.amountText.hasPrefix("300"), coffee.amountText)
        let request = try XCTUnwrap(QuickEntryLink.parse(try XCTUnwrap(URL(string: coffee.url))))
        XCTAssertEqual(request.mode, .expense)
        XCTAssertEqual(request.source, .widget)
        XCTAssertEqual(request.amount, 300)
        XCTAssertEqual(request.note, "Кофе")
        XCTAssertEqual(request.categoryId, Self.cafeId)
        XCTAssertEqual(request.accountId, Self.cardId)
        XCTAssertNil(request.currencyCode, "in the account's own currency")

        // Typed in dollars on a rouble card: the link says so.
        let uber = try XCTUnwrap(QuickEntryLink.parse(try XCTUnwrap(URL(string: items[1].url))))
        XCTAssertEqual(uber.amount, 9)
        XCTAssertEqual(uber.currencyCode, "USD")
        XCTAssertEqual(uber.accountId, Self.cardId)
        // A dollar account's own dollars need no currency.
        let netflix = try XCTUnwrap(QuickEntryLink.parse(try XCTUnwrap(URL(string: items[2].url))))
        XCTAssertEqual(netflix.amount, Decimal(string: "12.5"))
        XCTAssertNil(netflix.currencyCode)
        XCTAssertEqual(netflix.accountId, Self.usdId)
    }

    /// A widget's «Повторить» opens the sheet exactly as the in-sheet strip
    /// does: same phrase, amount, currency, category and account — and it
    /// is only a draft (nothing is saved by opening it).
    func test_repeatLink_seedsTheSheetLikeTheStrip() throws {
        let store = makeStore()
        let context = QuickEntryContext(dataStore: store, currencyManager: store.currencyManager)
        for candidate in QuickEntryPredictor.repeatCandidates(context: context, type: nil, limit: 3) {
            let widgetItem = SharedSnapshotWriter.repeatItem(candidate, context: context)
            let request = try XCTUnwrap(QuickEntryLink.parse(try XCTUnwrap(URL(string: widgetItem.url))))
            let seed = QuickEntrySheetModel.seed(for: request)

            let foreign = candidate.currencyCode != candidate.accountCurrency
            XCTAssertEqual(seed.text, QuickEntrySheetModel.phrase(description: candidate.description, amount: candidate.amount,
                                                                   currency: foreign ? candidate.currencyCode : nil))
            XCTAssertTrue(seed.hasPrefilledOverrides)
            XCTAssertEqual(seed.overrides.amount, candidate.amount)
            XCTAssertEqual(seed.overrides.accountId, candidate.accountId)
            XCTAssertEqual(seed.overrides.description, candidate.description)
            XCTAssertEqual(seed.overrides.currencyCode, foreign ? candidate.currencyCode : nil)
            if let category = candidate.categoryId {
                XCTAssertEqual(seed.overrides.category, .category(category))
            }
            let draft = QuickEntryEngine.draft(text: seed.text, mode: request.transactionType, overrides: seed.overrides,
                                               context: context, now: Self.now)
            XCTAssertEqual(draft.amount, candidate.amount)
            XCTAssertEqual(draft.accountId, candidate.accountId)
            XCTAssertEqual(draft.currencyCode, candidate.currencyCode)
        }
    }

    func test_repeatItems_emptyHistory() {
        let store = makeStore()
        store.transactions = []
        store.rebuildCaches()
        XCTAssertEqual(build(store).repeatItems, [])
    }

    // MARK: - Schema window

    private func json(_ snapshot: SharedSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SharedSnapshotStore.encode(snapshot)) as? [String: Any])
    }

    /// A 1.5.x file (v1, no account keys) still decodes: the old widgets
    /// keep their numbers, «Счёт» shows «Откройте Akifi», nothing crashes.
    func test_v1Payload_degradesToPlaceholderForTheNewWidgets() throws {
        var v1 = try json(SharedSnapshot.placeholder)
        v1["schemaVersion"] = 1
        for key in ["accounts", "monthKey", "repeatItems"] { v1.removeValue(forKey: key) }
        let decoded = try XCTUnwrap(SharedSnapshotStore.decode(JSONSerialization.data(withJSONObject: v1)))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.totalBalance, SharedSnapshot.placeholder.totalBalance)
        XCTAssertNil(decoded.accounts)
        XCTAssertNil(decoded.repeatItems)
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: decoded, accountId: Self.cardId), .signedOut)
        XCTAssertTrue(AccountWidgetEntityQuery.suggested(in: decoded).isEmpty)
        XCTAssertNil(AccountWidgetEntityQuery.defaultEntity(in: decoded))
        // Rolling a v1 payload over is harmless too.
        XCTAssertNil(decoded.rolledOver(to: Self.now.addingTimeInterval(40 * 86_400)).accounts)
    }

    func test_unreadablePayloads_areStale_notCrashes() throws {
        var future = try json(SharedSnapshot.placeholder)
        future["schemaVersion"] = 9_999
        XCTAssertNil(SharedSnapshotStore.decode(try JSONSerialization.data(withJSONObject: future)))
        future["schemaVersion"] = 0
        XCTAssertNil(SharedSnapshotStore.decode(try JSONSerialization.data(withJSONObject: future)))
        XCTAssertNil(SharedSnapshotStore.decode(Data("not json".utf8)))
        XCTAssertNil(SharedSnapshotStore.decode(Data(#"{"schemaVersion":2}"#.utf8)))
        // A v2 item missing a field is unreadable as a whole, not half-read.
        var broken = try json(build(makeStore()))
        var accounts = try XCTUnwrap(broken["accounts"] as? [[String: Any]])
        accounts[0].removeValue(forKey: "balance")
        broken["accounts"] = accounts
        XCTAssertNil(SharedSnapshotStore.decode(try JSONSerialization.data(withJSONObject: broken)))
        XCTAssertNil(AccountWidgetState.resolve(snapshot: nil, accountId: nil).account)
    }

    func test_v2_roundTrip() throws {
        let snapshot = build(makeStore(), hidden: [Self.usdId])
        let decoded = try XCTUnwrap(SharedSnapshotStore.decode(SharedSnapshotStore.encode(snapshot)))
        XCTAssertEqual(decoded, snapshot)
    }

    // MARK: - Rollover

    func test_newMonth_zeroesMonthFlow_keepsBalances() throws {
        let snapshot = build(makeStore())
        let sameMonth = snapshot.rolledOver(to: QE.date(2026, 11, 30, 12))
        XCTAssertEqual(try item(sameMonth, Self.cardId).monthIncome, 50_000_00)

        let december = snapshot.rolledOver(to: QE.date(2026, 12, 2, 12))
        let card = try item(december, Self.cardId)
        XCTAssertEqual(card.monthIncome, 0)
        XCTAssertEqual(card.monthExpense, 0)
        XCTAssertEqual(card.balance, 52_800_00)
        XCTAssertEqual(december.monthKey, "2026-12")
        XCTAssertEqual(december.repeatItems, snapshot.repeatItems)

        // The gallery sample has no month: never zeroed.
        let sample = SharedSnapshot.placeholder.rolledOver(to: Self.now)
        XCTAssertEqual(sample.accounts?.first?.monthIncome, SharedSnapshot.placeholder.accounts?.first?.monthIncome)
    }

    // MARK: - Account picker (entity query) and fallback

    private func snapshot(accounts: [SharedSnapshot.AccountItem]?) -> SharedSnapshot {
        var s = SharedSnapshot.placeholder
        s.accounts = accounts
        return s
    }

    private func account(_ id: String, primary: Bool = false) -> SharedSnapshot.AccountItem {
        SharedSnapshot.AccountItem(id: id, name: "A-\(id.suffix(2))", icon: "💳", colorHex: "#3B82F6",
                                   currencyCode: "RUB", currencySymbol: "₽", currencyDecimals: 0,
                                   balance: 1_00, monthIncome: 0, monthExpense: 0,
                                   isPrimary: primary, isShared: false, isBalanceHidden: false)
    }

    func test_query_defaultsToPrimary() {
        let s = snapshot(accounts: [account(Self.cashId), account(Self.cardId, primary: true), account(Self.usdId)])
        XCTAssertEqual(AccountWidgetEntityQuery.defaultEntity(in: s)?.id, Self.cardId)
        XCTAssertEqual(AccountWidgetEntityQuery.suggested(in: s).map(\.id), [Self.cashId, Self.cardId, Self.usdId])
        // Nobody marked primary → the first.
        let noPrimary = snapshot(accounts: [account(Self.cashId), account(Self.usdId)])
        XCTAssertEqual(AccountWidgetEntityQuery.defaultEntity(in: noPrimary)?.id, Self.cashId)
        XCTAssertNil(AccountWidgetEntityQuery.defaultEntity(in: snapshot(accounts: [])))
        XCTAssertNil(AccountWidgetEntityQuery.defaultEntity(in: nil))
    }

    func test_query_unknownOrDeletedId_fallsBackToPrimary() {
        let s = snapshot(accounts: [account(Self.cashId), account(Self.cardId, primary: true)])
        let deleted = "0a000000-0000-4000-8000-0000000000ff"
        XCTAssertEqual(AccountWidgetEntityQuery.entities(for: [deleted], in: s).map(\.id), [], "a stale id resolves to nothing")
        XCTAssertEqual(AccountWidgetEntityQuery.entities(for: [Self.cashId.uppercased(), deleted], in: s).map(\.id), [Self.cashId])
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: s, accountId: deleted).account?.id, Self.cardId)
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: s, accountId: Self.debtId).account?.id, Self.cardId,
                       "a debt account is never in the snapshot")
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: s, accountId: nil).account?.id, Self.cardId)
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: s, accountId: Self.cashId).account?.id, Self.cashId)
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: snapshot(accounts: []), accountId: deleted), .noAccounts)
        XCTAssertEqual(AccountWidgetState.resolve(snapshot: nil, accountId: Self.cashId), .signedOut)
    }

    func test_entity_displaysIconNameAndCurrency() {
        let entity = AccountWidgetEntity(account(Self.cardId, primary: true))
        XCTAssertEqual(entity.id, Self.cardId)
        XCTAssertEqual(entity.icon, "💳")
        XCTAssertEqual(entity.currencyCode, "RUB")
    }

    // MARK: - Links: one builder, one parser

    func test_link_roundTrip_withAccountAndCurrency() throws {
        let link = QuickEntryLaunchLink(
            mode: .income, source: .widget, text: "+5000 подарок & торт", amount: Decimal(string: "12.5"),
            currency: "usd", categoryId: Self.cafeId, accountId: Self.usdId, note: "мама"
        )
        let parsed = try XCTUnwrap(QuickEntryLaunchLink(url: link.url))
        XCTAssertEqual(parsed.mode, .income)
        XCTAssertEqual(parsed.source, .widget)
        XCTAssertEqual(parsed.text, "+5000 подарок & торт")
        XCTAssertEqual(parsed.amount, Decimal(string: "12.5"))
        XCTAssertEqual(parsed.currency, "USD")
        XCTAssertEqual(parsed.categoryId, Self.cafeId)
        XCTAssertEqual(parsed.accountId, Self.usdId)
        XCTAssertEqual(parsed.note, "мама")
        XCTAssertFalse(link.url.absoluteString.contains("+5000"), "a literal + would read as a space elsewhere")

        // The app's request → link → request.
        let request = try XCTUnwrap(QuickEntryLink.parse(link.url, now: Self.now))
        XCTAssertEqual(request.accountId, Self.usdId)
        XCTAssertEqual(request.currencyCode, "USD")
        XCTAssertEqual(request.overrides.accountId, Self.usdId)
        XCTAssertEqual(request.overrides.currencyCode, "USD")
        let again = try XCTUnwrap(QuickEntryLink.parse(QuickEntryLink.url(for: request), now: Self.now))
        XCTAssertEqual(again.link, request.link)
    }

    func test_link_dropsWhatItCannotTrust() throws {
        let url = try XCTUnwrap(URL(string: "akifi://quick-add?mode=expense&source=widget&account=\(Self.cardId.uppercased())&currency=US&category=x"))
        let parsed = try XCTUnwrap(QuickEntryLaunchLink(url: url))
        XCTAssertEqual(parsed.accountId, Self.cardId, "UUIDs lowercased like DB ids")
        XCTAssertNil(parsed.currency)
        XCTAssertNil(parsed.categoryId)
        // Three letters, but no currency the app knows.
        let zzz = try XCTUnwrap(URL(string: "akifi://quick-add?currency=ZZZ&amount=5"))
        XCTAssertEqual(QuickEntryLaunchLink(url: zzz)?.currency, "ZZZ")
        XCTAssertNil(QuickEntryLink.parse(zzz)?.currencyCode)
        // The first value wins over an appended duplicate.
        let dup = try XCTUnwrap(URL(string: "akifi://quick-add?account=\(Self.cardId)&account=\(Self.usdId)"))
        XCTAssertEqual(QuickEntryLaunchLink(url: dup)?.accountId, Self.cardId)
        XCTAssertNil(QuickEntryLaunchLink(url: try XCTUnwrap(URL(string: "akifi://home"))))
    }

    /// Widgets, Control Center and quick actions all build their URLs with
    /// `QuickEntryLaunchLink` and land in the same parser.
    func test_everyProducerUsesTheSharedBuilder() throws {
        let widgetExpense = AccountWidgetLinks.quickEntry(.expense, accountId: Self.cardId)
        XCTAssertEqual(widgetExpense, QuickEntryLaunchLink(mode: .expense, source: .widget, accountId: Self.cardId).url)
        let voice = try XCTUnwrap(QuickEntryLink.parse(AccountWidgetLinks.quickEntry(.voice, accountId: Self.usdId)))
        XCTAssertEqual(voice.mode, .voice)
        XCTAssertEqual(voice.accountId, Self.usdId)
        XCTAssertTrue(voice.startsWithVoice)

        XCTAssertEqual(QuickAddWidgetLinks.open(.income).absoluteString, "akifi://quick-add?mode=income&source=widget")

        for mode in QuickEntryLaunchMode.allCases {
            let type = QuickEntryLink.shortcutType(for: mode)
            XCTAssertEqual(QuickEntryLink.link(forShortcutType: type)?.url, QuickEntryLaunchLink(mode: mode, source: .quickAction).url)
            let request = try XCTUnwrap(QuickEntryLink.request(forShortcutType: type))
            XCTAssertEqual(request.mode, mode)
            XCTAssertEqual(request.source, .quickAction)
        }
        XCTAssertEqual(QuickEntryLaunchLink(mode: .expense, source: .control).url.absoluteString,
                       "akifi://quick-add?mode=expense&source=control")
    }

    func test_repeatItem_withUnusableURL_stillOpensQuickEntry() {
        let broken = SharedSnapshot.RepeatItem(id: "x", isIncome: true, title: "Зарплата", icon: nil,
                                               amountText: "1 ₽", accountName: nil, url: "https://example.com")
        XCTAssertEqual(QuickAddWidgetLinks.url(for: broken), QuickAddWidgetLinks.open(.income))
    }

    // MARK: - What a widget tap opens

    private func makeSheet(_ request: QuickEntryRequest, store: DataStore) -> QuickEntrySheetModel {
        let model = QuickEntrySheetModel(
            context: QuickEntryContext(dataStore: store, currencyManager: store.currencyManager),
            request: request,
            submitter: QuickEntrySubmitter(dataStore: store, currencyManager: nil),
            speech: SpeechQuickEntry(recognizer: SpeechQuickEntryTests.FakeRecognizer(),
                                     permissions: SpeechQuickEntryTests.FakePermissions(),
                                     locale: Locale(identifier: "ru-RU")),
            now: { Self.now }
        )
        model.largeExpenseDecision = { _ in nil }
        return model
    }

    func test_widgetButton_preselectsThatAccount() throws {
        let store = makeStore()
        let request = try XCTUnwrap(QuickEntryLink.parse(AccountWidgetLinks.quickEntry(.expense, accountId: Self.usdId)))
        let model = makeSheet(request, store: store)
        XCTAssertEqual(model.draft.accountId, Self.usdId)
        XCTAssertEqual(model.draft.currencyCode, "USD", "the account's own currency")
        XCTAssertEqual(model.source, .widget)
        XCTAssertFalse(model.canSave, "a widget tap is a draft without an amount — nothing is saved")
    }

    /// An unknown, deleted, «Долги» or someone else's id is ignored: the
    /// usual default account, never a crash or a booking on a debt.
    func test_widgetButton_foreignOrDebtAccount_fallsBackToDefault() throws {
        let store = makeStore()
        let defaultId = makeSheet(QuickEntryRequest(mode: .expense, source: .widget), store: store).draft.accountId
        XCTAssertNotNil(defaultId)
        for id in [Self.debtId, Self.futureId, "0a000000-0000-4000-8000-0000000000ff"] {
            let request = try XCTUnwrap(QuickEntryLink.parse(AccountWidgetLinks.quickEntry(.expense, accountId: id)))
            XCTAssertEqual(request.accountId, id, "the parser keeps a well-formed id…")
            XCTAssertEqual(makeSheet(request, store: store).draft.accountId, defaultId, "…the engine ignores it (\(id))")
        }
    }

    /// Cold start: the URL arrives before the signed-in UI; the request
    /// waits in the inbox and opens the sheet on that account once the UI
    /// takes it (and still waits while another sheet is up).
    func test_coldStart_inboxHoldsTheWidgetRequestForTheSheet() throws {
        let store = makeStore()
        let inbox = QuickEntryInbox()
        XCTAssertTrue(inbox.open(AccountWidgetLinks.quickEntry(.income, accountId: Self.cashId), now: Self.now))

        let coordinator = QuickEntryCoordinator()
        coordinator.makeSpeech = {
            SpeechQuickEntry(recognizer: SpeechQuickEntryTests.FakeRecognizer(),
                             permissions: SpeechQuickEntryTests.FakePermissions(),
                             locale: Locale(identifier: "ru-RU"))
        }
        XCTAssertNil(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: true, now: Self.now.addingTimeInterval(3)))
        XCTAssertNotNil(inbox.pending, "still waiting behind the other sheet")

        let request = try XCTUnwrap(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: false, now: Self.now.addingTimeInterval(8)))
        coordinator.present(request, dataStore: store, currencyManager: store.currencyManager)
        let model = try XCTUnwrap(coordinator.presented?.model)
        XCTAssertEqual(model.draft.type, .income)
        XCTAssertEqual(model.draft.accountId, Self.cashId)
        XCTAssertNil(inbox.pending)
    }

    // MARK: - Reloads

    func test_kindsToReload_onlyWhatChanged() {
        let store = makeStore()
        let base = build(store)
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: nil, to: base), AkifiWidgetKind.all)
        let older = SharedSnapshot(
            schemaVersion: 1, lastUpdated: base.lastUpdated, baseCurrency: base.baseCurrency,
            baseCurrencySymbol: base.baseCurrencySymbol, baseCurrencyDecimals: base.baseCurrencyDecimals,
            totalBalance: base.totalBalance, accountCount: base.accountCount, dailyLimit: base.dailyLimit,
            dailyLimitBudgetName: base.dailyLimitBudgetName, dailySpentToday: base.dailySpentToday,
            dailyLimitUtilization: base.dailyLimitUtilization, currentStreak: base.currentStreak,
            nextMilestone: base.nextMilestone, todayIncome: base.todayIncome, todayExpense: base.todayExpense,
            todayNet: base.todayNet, netWorth: base.netWorth
        )
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: older, to: base), AkifiWidgetKind.all, "a layout change reloads all")

        // A write that brought nothing new (only the timestamp moved).
        let rewritten = SharedSnapshotWriter.buildSnapshot(dataStore: store, currencyManager: store.currencyManager!,
                                                           now: Self.now.addingTimeInterval(60), hiddenBalanceIds: [])
        XCTAssertNotEqual(rewritten.lastUpdated, base.lastUpdated)
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: rewritten), [])

        // The eye toggle: only «Счёт».
        let hidden = build(store, hidden: [Self.cardId])
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: hidden), [AkifiWidgetKind.account])

        // «Повторить» moved: only «Быстрая запись».
        var repeats = base
        repeats.repeatItems = Array(base.repeatItems?.prefix(1) ?? [])
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: repeats), [AkifiWidgetKind.quickAdd])

        // A new day: the day-bound widgets.
        // (29th, not 28th: a later day in every time zone the simulator may have.)
        let tomorrow = base.rolledOver(to: QE.date(2026, 11, 29, 12))
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: tomorrow),
                       [AkifiWidgetKind.dailyLimit, AkifiWidgetKind.daySummary])

        // A new expense touches the totals, the day, the account and «Повторить».
        store.transactions.insert(Self.tx("t-new", Self.cardId, .expense, 100_00, raw: "2026-11-27T13:00:00", description: "Булочка"), at: 0)
        store.rebuildCaches()
        let afterSave = build(store)
        let kinds = SharedSnapshotWriter.kindsToReload(from: base, to: afterSave)
        XCTAssertTrue(kinds.isSuperset(of: [AkifiWidgetKind.balance, AkifiWidgetKind.daySummary, AkifiWidgetKind.account, AkifiWidgetKind.quickAdd]), "\(kinds)")
    }

    func test_widgetKinds_neverRenamed() {
        // Renaming a kind removes the widgets users already placed.
        XCTAssertEqual(AkifiWidgetKind.balance, "ru.akifi.widget.balance")
        XCTAssertEqual(AkifiWidgetKind.dailyLimit, "ru.akifi.widget.dailyLimit")
        XCTAssertEqual(AkifiWidgetKind.streak, "ru.akifi.widget.streak")
        XCTAssertEqual(AkifiWidgetKind.daySummary, "ru.akifi.widget.daySummary")
        XCTAssertEqual(AkifiWidgetKind.account, "ru.akifi.widget.account")
        XCTAssertEqual(AkifiWidgetKind.quickAdd, "ru.akifi.widget.quickAdd")
        XCTAssertEqual(AkifiWidgetKind.all.count, 6)
    }

    // MARK: - Formatting

    func test_money_inTheAccountCurrency() {
        let ru = Locale(identifier: "ru_RU")
        let rub = WidgetMoney.format(52_800_00, symbol: "₽", decimals: 0, locale: ru)
        XCTAssertEqual(rub.filter(\.isNumber), "52800")
        XCTAssertTrue(rub.hasSuffix(" ₽"))
        let usd = WidgetMoney.format(-487_50, symbol: "$", decimals: 2, locale: ru)
        XCTAssertTrue(usd.hasPrefix("−"))
        XCTAssertEqual(usd.filter(\.isNumber), "48750")
        XCTAssertEqual(WidgetMoney.format(1_200_00, symbol: "₽", decimals: 0, sign: .minus, locale: ru).first, "−")
        XCTAssertEqual(WidgetMoney.format(1_200_00, symbol: "₽", decimals: 0, sign: .plus, locale: ru).first, "+")
        XCTAssertEqual(WidgetMoney.format(0, symbol: "₽", decimals: 0, sign: .plus, locale: ru), "0 ₽")
    }
}

/// `HiddenBalances` reads the storage the Home carousel writes; the two
/// keys must never drift apart (the carousel's store is private to its file).
final class HiddenBalancesKeyGuardTests: XCTestCase {
    func test_sameKeyAsTheCarousel() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AkifiIOS/Views/Home/AccountCarouselView.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("App sources are not reachable from this test host")
        }
        let source = try String(contentsOf: file, encoding: .utf8)
        let usesShared = source.contains("HiddenBalances.defaultsKey") || source.contains("HiddenBalances.ids")
        XCTAssertTrue(usesShared || source.contains("\"\(HiddenBalances.defaultsKey)\""),
                      "the carousel's eye toggle must write `\(HiddenBalances.defaultsKey)` (or use HiddenBalances)")
    }
}
