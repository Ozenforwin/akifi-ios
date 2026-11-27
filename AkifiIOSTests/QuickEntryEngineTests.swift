import XCTest
@testable import AkifiIOS

/// Engine: phrase + mode + overrides + context → draft; and the write path
/// (`QuickEntrySubmitter`, ADR-001 fields, offline queue).
@MainActor
final class QuickEntryEngineTests: XCTestCase {

    private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    private var history: [Transaction] {
        [
            QE.tx("t1", "кофе", amount: 30000, category: "cat-cafe", account: "acc-cash", raw: "2026-11-26T09:00:00"),
            QE.tx("t2", "Зарплата", amount: 15_000_000, category: "cat-salary", account: "acc-sber", type: .income, raw: "2026-11-05T10:00:00"),
        ]
    }

    private func draft(
        _ text: String,
        mode: TransactionType? = nil,
        overrides: QuickEntryOverrides = QuickEntryOverrides(),
        context: QuickEntryContext? = nil
    ) -> QuickEntryDraft {
        QuickEntryEngine.draft(text: text, mode: mode, overrides: overrides, context: context ?? QE.context(transactions: history), now: QE.now)
    }

    // MARK: - Drafts

    func testCoffeeEndToEnd() {
        let result = draft("кофе 300")
        XCTAssertEqual(result.type, .expense)
        XCTAssertEqual(result.amount, 300)
        XCTAssertEqual(result.accountId, "acc-cash", "last used for expenses")
        XCTAssertEqual(result.currencyCode, "RUB", "the account's currency")
        XCTAssertEqual(result.categoryId, "cat-cafe", "same text in history")
        XCTAssertEqual(result.categorySource, .history)
        XCTAssertEqual(result.accountSource, .fallback)
        XCTAssertEqual(result.currencySource, .fallback)
        XCTAssertEqual(result.amountSource, .text)
        XCTAssertEqual(result.dateSource, .fallback)
        XCTAssertEqual(result.date, QE.now)
        XCTAssertEqual(result.description, "кофе")
        XCTAssertTrue(result.isReadyToSave)
    }

    func testIncomeFromKeywordLandsOnTheIncomeAccount() {
        let result = draft("зарплата 150 000")
        XCTAssertEqual(result.type, .income)
        XCTAssertEqual(result.typeSource, .text)
        XCTAssertEqual(result.accountId, "acc-sber")
        XCTAssertEqual(result.categoryId, "cat-salary")
    }

    func testCurrencyFollowsTheAccountUnlessNamed() {
        let usdFirst = QE.context(transactions: [
            QE.tx("t1", "gas", amount: 1000, category: nil, account: "acc-usd", raw: "2026-11-26T09:00:00"),
        ])
        XCTAssertEqual(draft("lunch 12", context: usdFirst).currencyCode, "USD")
        let euro = draft("€20 netflix", context: usdFirst)
        XCTAssertEqual(euro.currencyCode, "EUR")
        XCTAssertEqual(euro.currencySource, .text)
        XCTAssertEqual(euro.accountId, "acc-usd")
        // The user moves it to a RUB account: currency follows the account…
        let moved = draft("lunch 12", overrides: QuickEntryOverrides(accountId: "acc-card"), context: usdFirst)
        XCTAssertEqual(moved.currencyCode, "RUB")
        XCTAssertEqual(moved.accountSource, .user)
        // …but a named currency stays.
        XCTAssertEqual(draft("€20 netflix", overrides: QuickEntryOverrides(accountId: "acc-card"), context: usdFirst).currencyCode, "EUR")
    }

    func testAccountNamedInThePhrase() {
        let result = draft("продукты 1 234,56 с карты Тинькофф")
        XCTAssertEqual(result.accountId, "acc-card")
        XCTAssertEqual(result.accountSource, .text)
        XCTAssertEqual(result.amount, d("1234.56"))
    }

    func testTypePriority() {
        // Sign beats the mode the sheet was opened in.
        XCTAssertEqual(draft("-300 штраф", mode: .income).type, .expense)
        XCTAssertEqual(draft("+5000 подарок", mode: .expense).type, .income)
        // The mode beats keywords.
        XCTAssertEqual(draft("потратил 300", mode: .income).type, .income)
        // A command in the phrase beats the mode.
        XCTAssertEqual(draft("добавь доход 300", mode: .expense).type, .income)
        // The user's toggle beats everything.
        XCTAssertEqual(draft("+5000 подарок", overrides: QuickEntryOverrides(type: .expense)).type, .expense)
        // A named income category.
        XCTAssertEqual(draft("подарки 5000").type, .income)
        // How the same text was entered before.
        let rent = QE.context(transactions: [
            QE.tx("t1", "Аренда квартиры", amount: 3_000_000, category: nil, type: .income, raw: "2026-11-01T10:00:00"),
        ])
        let fromHistory = draft("аренда квартиры 30000", context: rent)
        XCTAssertEqual(fromHistory.type, .income)
        XCTAssertEqual(fromHistory.typeSource, .history)
        // Nothing said: expense.
        XCTAssertEqual(draft("что-то 100").typeSource, .fallback)
        // A transfer mode is ignored.
        XCTAssertEqual(draft("кофе 300", mode: .transfer).type, .expense)
    }

    func testCategoryOverrides() {
        XCTAssertEqual(draft("кофе 300", overrides: QuickEntryOverrides(category: .category("cat-food"))).categoryId, "cat-food")
        XCTAssertNil(draft("кофе 300", overrides: QuickEntryOverrides(category: .none)).categoryId)
        // A pick of the other type does not survive a type switch.
        let switched = draft("кофе 300", overrides: QuickEntryOverrides(type: .income, category: .category("cat-food")))
        XCTAssertNil(switched.categoryId)
        XCTAssertTrue(switched.suggestions.allSatisfy { $0.categoryId != "cat-food" })
        // A weak guess is offered, not applied.
        let unknown = draft("что-то 100")
        XCTAssertNil(unknown.categoryId)
        XCTAssertEqual(unknown.categorySource, .fallback)
        XCTAssertFalse(unknown.suggestions.isEmpty)
    }

    func testNotReadyWithoutAmountOrAccount() {
        XCTAssertFalse(draft("кофе").isReadyToSave)
        let noAccounts = QE.context(accounts: [QE.deposit])
        XCTAssertNil(draft("кофе 300", context: noAccounts).accountId)
        XCTAssertFalse(draft("кофе 300", context: noAccounts).isReadyToSave)
        XCTAssertEqual(draft("кофе 300", context: QE.context(accounts: [], fallbackCurrency: "kzt")).currencyCode, "KZT")
    }

    func testParsedDateAndUserDate() {
        XCTAssertEqual(QE.day(draft("такси 500 вчера").date), "2026-11-26")
        XCTAssertEqual(draft("такси 500 вчера").dateSource, .text)
        let picked = QE.date(2026, 11, 1, 9)
        XCTAssertEqual(draft("такси 500 вчера", overrides: QuickEntryOverrides(date: picked)).date, picked)
    }

    func testContextualStrings() {
        let strings = QuickEntryEngine.contextualStrings(context: QE.context(transactions: history))
        XCTAssertTrue(strings.contains("Тинькофф"))
        XCTAssertTrue(strings.contains("Кафе"))
        XCTAssertTrue(strings.contains("кофе"))
        XCTAssertEqual(strings.count, Set(strings.map { $0.lowercased() }).count, "no duplicates")
    }

    // MARK: - Write path (ADR-001)

    func testInputForANativeEntry() throws {
        let entry = draft("кофе 300")
        let input = try QuickEntrySubmitter.makeInput(
            draft: entry, account: QE.cash, userId: "u-live", rates: [:], categories: [QE.cafe, QE.groceries]
        )
        XCTAssertEqual(input.user_id, "u-live")
        XCTAssertEqual(input.account_id, "acc-cash")
        XCTAssertEqual(input.amount_native, 300)
        XCTAssertEqual(input.amount, 300)
        XCTAssertEqual(input.currency, "RUB")
        XCTAssertNil(input.foreign_amount)
        XCTAssertNil(input.foreign_currency)
        XCTAssertNil(input.fx_rate)
        XCTAssertEqual(input.type, "expense")
        XCTAssertEqual(input.category_id, "cat-cafe")
        XCTAssertEqual(input.description, "кофе")
        XCTAssertNil(input.payment_source_account_id, "plain expense, like the form")
        XCTAssertEqual(input.date, TransactionFormDates.string(from: QE.now))
    }

    func testInputForAForeignEntryConvertsIntoTheAccountCurrency() throws {
        let entry = draft("€20 netflix")
        // USD-based table: 1 USD = 0.5 EUR = 100 RUB → 20 € = 4 000 ₽.
        let input = try QuickEntrySubmitter.makeInput(
            draft: entry, account: QE.card, userId: "u", rates: ["USD": 1, "EUR": 0.5, "RUB": 100], categories: []
        )
        XCTAssertEqual(input.amount_native, 4000)
        XCTAssertEqual(input.currency, "RUB")
        XCTAssertEqual(input.foreign_amount, 20)
        XCTAssertEqual(input.foreign_currency, "EUR")
        XCTAssertEqual(input.fx_rate, 200)
        XCTAssertEqual(input.description, "netflix")
    }

    func testForeignEntryWithoutARateIsRefused() {
        let entry = draft("€20 netflix")
        XCTAssertThrowsError(try QuickEntrySubmitter.makeInput(draft: entry, account: QE.card, userId: "u", rates: [:], categories: [])) {
            XCTAssertTrue($0 is MissingFXRateError)
        }
    }

    func testInvalidDraftsAreRefused() {
        var entry = draft("кофе 300")
        entry.categoryId = "cat-salary"
        XCTAssertThrowsError(try QuickEntrySubmitter.makeInput(draft: entry, account: QE.cash, userId: "u", rates: [:], categories: [QE.salary])) {
            XCTAssertEqual($0 as? QuickEntrySubmitError, .invalidCategory)
        }
        entry.categoryId = "cat-unknown"
        XCTAssertThrowsError(try QuickEntrySubmitter.makeInput(draft: entry, account: QE.cash, userId: "u", rates: [:], categories: [QE.cafe]))
        var noAmount = draft("кофе")
        XCTAssertThrowsError(try QuickEntrySubmitter.makeInput(draft: noAmount, account: QE.cash, userId: "u", rates: [:], categories: [])) {
            XCTAssertEqual($0 as? QuickEntrySubmitError, .missingAmount)
        }
        noAmount.amount = 300
        noAmount.type = .transfer
        XCTAssertThrowsError(try QuickEntrySubmitter.makeInput(draft: noAmount, account: QE.cash, userId: "u", rates: [:], categories: [])) {
            XCTAssertEqual($0 as? QuickEntrySubmitError, .unsupportedType)
        }
    }

    func testAmountIsRoundedForTheEntryCurrency() throws {
        var vnd = draft("фо 50000.6 VND")
        vnd.accountId = "acc-vnd"
        vnd.categoryId = nil
        let account = QE.account("acc-vnd", "Вьетнам", currency: "VND")
        let input = try QuickEntrySubmitter.makeInput(draft: vnd, account: account, userId: "u", rates: [:], categories: [])
        XCTAssertEqual(input.amount_native, 50001, "VND has no minor units")
        var precise = draft("кофе 1234.567")
        precise.categoryId = nil
        let kopecks = try QuickEntrySubmitter.makeInput(draft: precise, account: QE.card, userId: "u", rates: [:], categories: [])
        XCTAssertEqual(kopecks.amount_native, d("1234.57"))
    }

    func testSubmitGoesThroughTheDataStoreOfflineQueue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QE-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DataStore(cache: PersistenceManager(directory: dir))
        store.isConnectedProvider = { false }
        store.accounts = [QE.card, QE.cash]
        store.categories = [QE.cafe, QE.groceries]
        store.rebuildCaches()

        var submitter = QuickEntrySubmitter(dataStore: store, currencyManager: nil)
        submitter.userId = { "u-live" }
        submitter.rates = { _ in XCTFail("no FX for a native entry"); return [:] }

        let context = QuickEntryContext(dataStore: store)
        let entry = QuickEntryEngine.draft(text: "кофе 300 наличными", context: context, now: QE.now)
        XCTAssertEqual(entry.accountId, "acc-cash")
        let tx = try await submitter.submit(entry)

        XCTAssertEqual(tx.accountId, "acc-cash")
        XCTAssertEqual(tx.amountNative, 30000)
        XCTAssertEqual(tx.type, .expense)
        XCTAssertEqual(store.transactions.first?.id, tx.id)
        XCTAssertTrue(store.offlineQueue.hasPending, "queued like any offline create")
        XCTAssertEqual(store.balance(for: QE.cash), -30000)
    }

    func testSubmitRefusesAGoneAccount() async {
        let store = DataStore(cache: PersistenceManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent("QE-\(UUID().uuidString)")))
        store.isConnectedProvider = { false }
        store.accounts = [QE.card]
        var submitter = QuickEntrySubmitter(dataStore: store, currencyManager: nil)
        submitter.userId = { "u" }
        var entry = QuickEntryEngine.draft(text: "кофе 300", context: QuickEntryContext(dataStore: store), now: QE.now)
        entry.accountId = "acc-deleted"
        do {
            try await submitter.submit(entry)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? QuickEntrySubmitError, .unknownAccount)
        }
        XCTAssertFalse(store.offlineQueue.hasPending)
    }

    func testLargeExpenseDecisionUsesTheFormGuard() {
        let store = DataStore(cache: PersistenceManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent("QE-\(UUID().uuidString)")))
        store.accounts = [QE.card]
        let submitter = QuickEntrySubmitter(dataStore: store, currencyManager: nil)
        XCTAssertNil(submitter.largeExpenseDecision(for: QuickEntryEngine.draft(text: "кофе", context: QuickEntryContext(dataStore: store), now: QE.now)))
        XCTAssertNotNil(submitter.largeExpenseDecision(for: QuickEntryEngine.draft(text: "кофе 300", context: QuickEntryContext(dataStore: store), now: QE.now)))
    }
}
