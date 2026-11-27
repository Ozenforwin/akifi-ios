import XCTest
@testable import AkifiIOS

/// 1.6 Liquid Glass sweep — Transactions / Assistant / Auth stream.
/// The logic that moved while restyling: the Transactions tab searches with
/// the system `.searchable` field (matching, suggestions and history left
/// the old search sheet), the filter sheet's period picker gained the
/// custom range as a segment, and the auth text field signals its state
/// without coloured borders.
final class GlassSweepTransactionsAssistantAuthTests: XCTestCase {

    private func tx(
        _ id: String,
        description: String? = nil,
        merchant: String? = nil,
        categoryId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: "u", accountId: "a", amount: 100, currency: "RUB",
            description: description, categoryId: categoryId, type: .expense, date: "2026-11-20",
            merchantName: merchant, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    // MARK: - Search matching

    func test_search_emptyQueryMatchesEverything() {
        XCTAssertTrue(TransactionSearch.matches(tx("1"), query: "", categoryName: nil))
    }

    func test_search_matchesDescriptionMerchantAndCategory_caseInsensitive() {
        let row = tx("1", description: "Ужин с друзьями", merchant: "Starbucks")
        XCTAssertTrue(TransactionSearch.matches(row, query: "УЖИН", categoryName: nil))
        XCTAssertTrue(TransactionSearch.matches(row, query: "starb", categoryName: nil))
        XCTAssertTrue(TransactionSearch.matches(row, query: "кафе", categoryName: "Кафе и рестораны"))
        XCTAssertFalse(TransactionSearch.matches(row, query: "такси", categoryName: "Кафе и рестораны"))
    }

    func test_search_rowWithoutTextFieldsMatchesOnlyThroughTheCategory() {
        let row = tx("1")
        XCTAssertFalse(TransactionSearch.matches(row, query: "прод", categoryName: nil))
        XCTAssertTrue(TransactionSearch.matches(row, query: "прод", categoryName: "Продукты"))
    }

    // MARK: - Suggestions

    func test_suggestions_merchantsByFrequency_tiesAlphabetical() {
        let rows = [
            tx("1", merchant: "Lenta"), tx("2", merchant: "Lenta"), tx("3", merchant: "Lenta"),
            tx("4", merchant: "Yandex Go"), tx("5", merchant: "Yandex Go"),
            tx("6", merchant: "Bolt"), tx("7", merchant: "Bolt"),
            tx("8", merchant: "")
        ]
        XCTAssertEqual(TransactionSearch.suggestions(from: rows), ["Lenta", "Bolt", "Yandex Go"])
    }

    func test_suggestions_keywordsSkipShortWordsPunctuationAndMerchants() {
        let rows = [
            tx("1", description: "Кофе, latte и круассан", merchant: "Latte"),
            tx("2", description: "кофе на вынос!"),
            tx("3", description: "КОФЕ")
        ]
        // "кофе" ×3 first; "и"/"на" are too short; "latte" is a merchant.
        XCTAssertEqual(TransactionSearch.suggestions(from: rows), ["Latte", "кофе", "вынос", "круассан"])
    }

    func test_suggestions_areCappedAt10MerchantsAnd5Keywords() {
        var rows: [Transaction] = []
        for i in 0..<15 { rows.append(tx("m\(i)", merchant: "Shop \(String(format: "%02d", i))")) }
        for i in 0..<8 { rows.append(tx("d\(i)", description: "word\(i)")) }
        let suggestions = TransactionSearch.suggestions(from: rows)
        XCTAssertEqual(suggestions.count, TransactionSearch.merchantSuggestionLimit + TransactionSearch.keywordSuggestionLimit)
        XCTAssertEqual(suggestions.first, "Shop 00")
        XCTAssertEqual(suggestions.last, "word4")
    }

    // MARK: - History

    func test_history_addingMovesTheTermToTheFront_trimmed_unique() {
        let history = ["кофе", "такси", "аптека"]
        XCTAssertEqual(TransactionSearchHistory.adding("  такси \n", to: history), ["такси", "кофе", "аптека"])
        XCTAssertEqual(TransactionSearchHistory.adding("кино", to: history), ["кино", "кофе", "такси", "аптека"])
    }

    func test_history_blankTermsLeaveItUnchanged() {
        XCTAssertEqual(TransactionSearchHistory.adding("   ", to: ["кофе"]), ["кофе"])
        XCTAssertEqual(TransactionSearchHistory.adding("", to: []), [])
    }

    func test_history_isCappedAt20() {
        let full = (0..<TransactionSearchHistory.limit).map { "q\($0)" }
        let updated = TransactionSearchHistory.adding("new", to: full)
        XCTAssertEqual(updated.count, TransactionSearchHistory.limit)
        XCTAssertEqual(updated.first, "new")
        XCTAssertFalse(updated.contains("q19"))
    }

    func test_history_persistsUnderThePre16Key() throws {
        let suite = "GlassSweepSearchHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // History written by the old search sheet carries over.
        defaults.set(try JSONEncoder().encode(["старый запрос"]), forKey: "searchHistory")
        let store = TransactionSearchHistory(defaults: defaults)
        XCTAssertEqual(store.load(), ["старый запрос"])

        store.save(["новый", "старый запрос"])
        XCTAssertEqual(TransactionSearchHistory(defaults: defaults).load(), ["новый", "старый запрос"])
        XCTAssertEqual(TransactionSearchHistory.defaultsKey, "searchHistory")
    }

    // MARK: - Filter period

    private typealias Period = TransactionFilterSheet.FilterPeriod

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return cal
    }

    private func date(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return f.date(from: text)!
    }

    func test_period_presetsEndNow() {
        let now = date("2026-11-27T15:30:00+03:00")
        let from = date("2026-10-01T00:00:00+03:00")
        let to = date("2026-10-31T00:00:00+03:00")

        let all = Period.all.dateRange(now: now, calendar: calendar, customFrom: from, customTo: to)
        XCTAssertNil(all.from)
        XCTAssertNil(all.to)

        let today = Period.today.dateRange(now: now, calendar: calendar, customFrom: from, customTo: to)
        XCTAssertEqual(today.from, date("2026-11-27T00:00:00+03:00"))
        XCTAssertEqual(today.to, now)

        let week = Period.week.dateRange(now: now, calendar: calendar, customFrom: from, customTo: to)
        XCTAssertEqual(week.from, date("2026-11-20T15:30:00+03:00"))
        XCTAssertEqual(week.to, now)

        let month = Period.month.dateRange(now: now, calendar: calendar, customFrom: from, customTo: to)
        XCTAssertEqual(month.from, date("2026-10-27T15:30:00+03:00"))
        XCTAssertEqual(month.to, now)
    }

    func test_period_customTakesTheCalendarRange() {
        let from = date("2026-10-01T00:00:00+03:00")
        let to = date("2026-10-31T00:00:00+03:00")
        let custom = Period.custom.dateRange(now: Date(), calendar: calendar, customFrom: from, customTo: to)
        XCTAssertEqual(custom.from, from)
        XCTAssertEqual(custom.to, to)
    }

    func test_period_customIsTheLastSegment() {
        XCTAssertEqual(Period.allCases, [.all, .today, .week, .month, .custom])
    }

    // MARK: - Auth text field state

    func test_authField_errorWinsOverValid() {
        XCTAssertEqual(AuthTextField.validationState(errorMessage: "Неверный email", isValid: true), .invalid)
    }

    func test_authField_validAndNeutral() {
        XCTAssertEqual(AuthTextField.validationState(errorMessage: nil, isValid: true), .valid)
        XCTAssertEqual(AuthTextField.validationState(errorMessage: "", isValid: true), .valid)
        XCTAssertEqual(AuthTextField.validationState(errorMessage: nil, isValid: nil), .neutral)
        XCTAssertEqual(AuthTextField.validationState(errorMessage: nil, isValid: false), .neutral)
    }
}
