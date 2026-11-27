import XCTest
@testable import AkifiIOS

/// Category prediction, «repeat recent» and defaults from history.
final class QuickEntryPredictorTests: XCTestCase {

    private func rank(
        _ text: String,
        type: TransactionType = .expense,
        accountId: String? = nil,
        at entryDate: Date = QE.now,
        hints: [QuickEntryParse.CategoryHint] = [],
        context: QuickEntryContext
    ) -> [QuickEntryCategorySuggestion] {
        QuickEntryPredictor.rankCategories(
            text: text, type: type, accountId: accountId, entryDate: entryDate,
            nameHints: hints, context: context, now: QE.now
        )
    }

    // MARK: - Same text

    func testSameTextUsesTheMostRecentCategory() {
        let context = QE.context(transactions: [
            // Filed under «Продукты» three times long ago, under «Кафе» yesterday.
            QE.tx("t1", "кофе", amount: 30000, category: "cat-food", raw: "2026-09-01T09:00:00"),
            QE.tx("t2", "Кофе", amount: 30000, category: "cat-food", raw: "2026-09-02T09:00:00"),
            QE.tx("t3", "кофе", amount: 30000, category: "cat-food", raw: "2026-09-03T09:00:00"),
            QE.tx("t4", "Кофе!", amount: 30000, category: "cat-cafe", raw: "2026-11-26T09:00:00"),
        ])
        let result = rank("кофе", context: context)
        XCTAssertEqual(result.first?.categoryId, "cat-cafe")
        XCTAssertEqual(result.first?.reason, .sameText)
        XCTAssertGreaterThanOrEqual(result.first!.confidence, QuickEntryPredictor.autoApplyThreshold)
        XCTAssertEqual(result[1].categoryId, "cat-food")
        XCTAssertLessThan(result[1].confidence, result[0].confidence)
    }

    func testMerchantCountsAsSameText() {
        let context = QE.context(transactions: [
            QE.tx("t1", nil, amount: 50000, category: "cat-food", raw: "2026-11-20T18:00:00", merchant: "Пятёрочка"),
        ])
        let result = rank("пятерочка", context: context)
        XCTAssertEqual(result.first?.categoryId, "cat-food")
        XCTAssertEqual(result.first?.reason, .sameText)
    }

    func testInflectedTextIsTheSameText() {
        let context = QE.context(transactions: [
            QE.tx("t1", "Зарплата", amount: 15_000_000, category: "cat-salary", type: .income, raw: "2026-11-05T10:00:00"),
        ])
        XCTAssertEqual(rank("зарплату", type: .income, context: context).first?.categoryId, "cat-salary")
    }

    // MARK: - Types never mix

    func testExpenseAndIncomeAreSeparate() {
        let context = QE.context(transactions: [
            QE.tx("t1", "подарок", amount: 500000, category: "cat-gifts", type: .income, raw: "2026-11-20T10:00:00"),
        ])
        XCTAssertTrue(rank("подарок", type: .expense, context: context).allSatisfy { $0.categoryId != "cat-gifts" })
        XCTAssertEqual(rank("подарок", type: .income, context: context).first?.categoryId, "cat-gifts")
        XCTAssertTrue(rank("кофе", type: .transfer, context: context).isEmpty)
    }

    // MARK: - Hidden and shared categories (DataStore.displayCategories rules)

    func testHiddenCategoryIsNeverSuggested() {
        let hidden = QE.category("cat-old", "Старое кафе", active: false)
        let context = QE.context(
            categories: [QE.cafe, QE.groceries, hidden],
            transactions: [QE.tx("t1", "латте", amount: 30000, category: "cat-old", raw: "2026-11-26T09:00:00")]
        )
        XCTAssertTrue(rank("латте", context: context).isEmpty)
        XCTAssertTrue(rank("", context: context).allSatisfy { $0.categoryId != "cat-old" })
    }

    func testPartnerDuplicateCountsForTheDisplayTwin() {
        // The partner's «Кафе» on a shared account dedups onto mine.
        let partnerCafe = QE.category("cat-partner-cafe", "Кафе", userId: QE.partner, createdAt: "2025-01-01T00:00:00Z")
        let categories = [QE.cafe, QE.groceries, partnerCafe]
        let display = [QE.cafe, QE.groceries]   // what DataStore.displayCategories returns
        let context = QE.context(
            categories: categories,
            display: display,
            transactions: [QE.tx("t1", "латте", amount: 30000, category: "cat-partner-cafe", raw: "2026-11-26T09:00:00", userId: QE.partner)]
        )
        XCTAssertEqual(context.displayCategoryIdById["cat-partner-cafe"], "cat-cafe")
        XCTAssertEqual(rank("латте", context: context).first?.categoryId, "cat-cafe")
    }

    func testHiddenCategoryWithAVisibleTwinMapsToTheTwin() {
        let myHiddenCafe = QE.category("cat-my-cafe", "Кафе", active: false)
        let sharedCafe = QE.category("cat-shared-cafe", "Кафе", userId: QE.partner)
        let context = QE.context(
            categories: [myHiddenCafe, sharedCafe],
            display: [sharedCafe],
            transactions: [QE.tx("t1", "латте", amount: 30000, category: "cat-my-cafe", raw: "2026-11-26T09:00:00")]
        )
        XCTAssertEqual(rank("латте", context: context).first?.categoryId, "cat-shared-cafe")
    }

    // MARK: - Name, similarity, frequency

    func testCategoryNameWithoutHistory() {
        let context = QE.context()
        let parse = QE.parse("такси 500", vocabulary: context.vocabulary)
        let result = rank(parse.description, hints: parse.categoryHints, context: context)
        XCTAssertEqual(result.first?.categoryId, "cat-taxi")
        XCTAssertEqual(result.first?.reason, .categoryName)
        XCTAssertGreaterThanOrEqual(result.first!.confidence, QuickEntryPredictor.autoApplyThreshold)
    }

    func testSameTextBeatsCategoryName() {
        // The user files «такси» under «Продукты»?! Their history wins.
        let context = QE.context(transactions: [
            QE.tx("t1", "такси", amount: 50000, category: "cat-food", raw: "2026-11-25T09:00:00"),
        ])
        let parse = QE.parse("такси 500", vocabulary: context.vocabulary)
        let result = rank(parse.description, hints: parse.categoryHints, context: context)
        XCTAssertEqual(result.map(\.categoryId).prefix(2), ["cat-food", "cat-taxi"])
    }

    func testSimilarText() {
        let context = QE.context(transactions: [
            QE.tx("t1", "латте с собой", amount: 30000, category: "cat-cafe", raw: "2026-11-20T09:00:00"),
            QE.tx("t2", "хлеб молоко", amount: 30000, category: "cat-food", raw: "2026-11-21T19:00:00"),
        ])
        let result = rank("латте большой", context: context)
        XCTAssertEqual(result.first?.categoryId, "cat-cafe")
        XCTAssertEqual(result.first?.reason, .similarText)
    }

    func testFrequencyFollowsTimeOfDayAndStaysBelowAutoApply() {
        var rows: [Transaction] = []
        // Mornings: «Кафе»; evenings: «Продукты». Same counts, same days.
        for day in 10...20 {
            rows.append(QE.tx("m\(day)", "утро \(day)", amount: 30000, category: "cat-cafe", raw: "2026-11-\(day)T08:30:00"))
            rows.append(QE.tx("e\(day)", "вечер \(day)", amount: 90000, category: "cat-food", raw: "2026-11-\(day)T20:00:00"))
        }
        let context = QE.context(transactions: rows)
        let morning = rank("", at: QE.date(2026, 11, 27, 8, 40), context: context)
        let evening = rank("", at: QE.date(2026, 11, 27, 20, 10), context: context)
        XCTAssertEqual(morning.first?.categoryId, "cat-cafe")
        XCTAssertEqual(evening.first?.categoryId, "cat-food")
        XCTAssertEqual(morning.first?.reason, .frequent)
        XCTAssertTrue(morning.allSatisfy { $0.confidence < QuickEntryPredictor.autoApplyThreshold })
    }

    func testRecentUseOutweighsOldUse() {
        var rows: [Transaction] = []
        for i in 0..<5 { rows.append(QE.tx("old\(i)", "x\(i)", amount: 100, category: "cat-food", raw: "2026-01-1\(i)T12:00:00")) }
        for i in 0..<3 { rows.append(QE.tx("new\(i)", "y\(i)", amount: 100, category: "cat-cafe", raw: "2026-11-2\(i)T12:00:00")) }
        XCTAssertEqual(rank("", context: QE.context(transactions: rows)).first?.categoryId, "cat-cafe")
    }

    func testTransfersAreNotHistory() {
        let context = QE.context(transactions: [
            QE.tx("t1", "кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-26T09:00:00", transferGroupId: "g1"),
        ])
        XCTAssertTrue(context.history.isEmpty)
        XCTAssertTrue(rank("кофе", context: context).isEmpty)
    }

    func testHistoryType() {
        let context = QE.context(transactions: [
            QE.tx("t1", "Аренда квартиры", amount: 3_000_000, category: nil, type: .income, raw: "2026-11-01T10:00:00"),
            QE.tx("t2", "кофе", amount: 30000, category: nil, raw: "2026-11-01T10:00:00"),
            QE.tx("t3", "кофе", amount: 30000, category: nil, type: .income, raw: "2026-11-02T10:00:00"),
        ])
        XCTAssertEqual(QuickEntryPredictor.historyType(for: "аренда квартиры", context: context), .income)
        XCTAssertNil(QuickEntryPredictor.historyType(for: "кофе", context: context), "both types seen")
        XCTAssertNil(QuickEntryPredictor.historyType(for: "новое", context: context))
    }

    // MARK: - Repeat recent

    func testRepeatCandidates() {
        let context = QE.context(transactions: [
            QE.tx("t1", "Кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-26T09:00:00"),
            QE.tx("t2", "кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-25T09:00:00"),
            QE.tx("t3", "Кофе", amount: 35000, category: "cat-cafe", raw: "2026-11-24T09:00:00"),
            QE.tx("t4", "Такси", amount: 50000, category: "cat-taxi", account: "acc-cash", raw: "2026-11-23T09:00:00"),
            // Partner's row on a shared account — not mine to repeat.
            QE.tx("t5", "Пиво", amount: 20000, category: "cat-food", raw: "2026-11-26T22:00:00", userId: QE.partner),
            // Deleted account.
            QE.tx("t6", "Обед", amount: 40000, category: "cat-food", account: "acc-gone", raw: "2026-11-26T13:00:00"),
            // Nothing to repeat: no description, no category.
            QE.tx("t7", nil, amount: 10000, category: nil, raw: "2026-11-26T15:00:00"),
            QE.tx("t8", "Зарплата", amount: 15_000_000, category: "cat-salary", type: .income, raw: "2026-11-05T10:00:00"),
        ])
        let all = QuickEntryPredictor.repeatCandidates(context: context)
        XCTAssertEqual(all.map(\.sourceTransactionId), ["t1", "t3", "t4", "t8"])
        XCTAssertEqual(all[0].useCount, 2)
        XCTAssertEqual(all[0].amount, 300)
        XCTAssertEqual(all[0].currencyCode, "RUB")
        XCTAssertEqual(all[0].amountNative, 30000)

        let expenses = QuickEntryPredictor.repeatCandidates(context: context, type: .expense, limit: 2)
        XCTAssertEqual(expenses.map(\.sourceTransactionId), ["t1", "t3"])
        XCTAssertEqual(QuickEntryPredictor.repeatCandidates(context: context, type: .income).map(\.sourceTransactionId), ["t8"])
    }

    func testRepeatOfAForeignEntryRepeatsTheForeignAmount() {
        // 50 000 VND entered on a RUB account (ADR-001: native 190 ₽).
        let context = QE.context(transactions: [
            QE.tx("t1", "Фо бо", amount: 19000, category: "cat-cafe", raw: "2026-11-26T12:00:00",
                  foreignAmount: 50000, foreignCurrency: "vnd"),
        ])
        let item = QuickEntryPredictor.repeatCandidates(context: context).first!
        XCTAssertEqual(item.amount, 50000)
        XCTAssertEqual(item.currencyCode, "VND")
        XCTAssertEqual(item.amountNative, 19000)
        XCTAssertEqual(item.accountCurrency, "RUB")

        let draft = QuickEntryEngine.draft(repeating: item, context: context, now: QE.now)
        XCTAssertEqual(draft.amount, 50000)
        XCTAssertEqual(draft.currencyCode, "VND")
        XCTAssertEqual(draft.accountId, "acc-card")
        XCTAssertEqual(draft.categoryId, "cat-cafe")
        XCTAssertEqual(draft.description, "Фо бо")
        XCTAssertEqual(draft.date, QE.now)
    }

    func testRepeatDropsAHiddenCategory() {
        let hidden = QE.category("cat-old", "Старое", active: false)
        let context = QE.context(
            categories: [QE.cafe, hidden],
            transactions: [QE.tx("t1", "Кофе", amount: 30000, category: "cat-old", raw: "2026-11-26T09:00:00")]
        )
        let item = QuickEntryPredictor.repeatCandidates(context: context).first!
        XCTAssertNil(item.categoryId)
        XCTAssertNil(QuickEntryEngine.draft(repeating: item, context: context, now: QE.now).categoryId)
    }

    // MARK: - Defaults

    func testDefaultAccountIsTheLastUsedForTheType() {
        let context = QE.context(transactions: [
            QE.tx("t1", "кофе", amount: 100, category: nil, account: "acc-cash", raw: "2026-11-26T09:00:00"),
            QE.tx("t2", "обед", amount: 100, category: nil, account: "acc-card", raw: "2026-11-25T09:00:00"),
            QE.tx("t3", "зп", amount: 100, category: nil, account: "acc-sber", type: .income, raw: "2026-11-05T09:00:00"),
        ])
        XCTAssertEqual(QuickEntryDefaults.defaultAccount(for: .expense, context: context)?.id, "acc-cash")
        XCTAssertEqual(QuickEntryDefaults.defaultAccount(for: .income, context: context)?.id, "acc-sber")
    }

    func testDefaultAccountSkipsDepositsAndPartnersAndFallsBackToPrimary() {
        let context = QE.context(transactions: [
            QE.tx("t1", "вклад", amount: 100, category: nil, account: "acc-dep", raw: "2026-11-26T09:00:00"),
            QE.tx("t2", "пиво", amount: 100, category: nil, account: "acc-sber", raw: "2026-11-26T10:00:00", userId: QE.partner),
        ])
        XCTAssertEqual(QuickEntryDefaults.defaultAccount(for: .expense, context: context)?.id, "acc-card", "primary")
        XCTAssertFalse(QuickEntryDefaults.isEligibleDefault(QE.deposit))
        XCTAssertTrue(QuickEntryDefaults.isEligibleDefault(QE.cash))
    }

    func testDefaultAccountWithoutPrimaryOrAccounts() {
        let noPrimary = QE.context(accounts: [QE.deposit, QE.sber, QE.cash])
        XCTAssertEqual(QuickEntryDefaults.defaultAccount(for: .expense, context: noPrimary)?.id, "acc-sber")
        let onlyDeposit = QE.context(accounts: [QE.deposit])
        XCTAssertNil(QuickEntryDefaults.defaultAccount(for: .expense, context: onlyDeposit))
        XCTAssertEqual(QuickEntryDefaults.currency(for: nil, context: QE.context(fallbackCurrency: "eur")), "EUR")
        XCTAssertEqual(QuickEntryDefaults.currency(for: QE.usd, context: QE.context()), "USD")
    }

    func testHourOfStoredTimestamps() {
        XCTAssertEqual(QuickEntryContext.hour(of: "2026-11-17T08:30:00"), 8)
        XCTAssertEqual(QuickEntryContext.hour(of: "2026-11-17T23:30:00+00:00"), 23)
        XCTAssertEqual(QuickEntryContext.hour(of: "2026-11-17 07:05:00+00"), 7)
        XCTAssertNil(QuickEntryContext.hour(of: "2026-11-17"))
    }
}
