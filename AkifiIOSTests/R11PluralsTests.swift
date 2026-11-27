import XCTest
@testable import AkifiIOS

/// R6 / R11: count strings carry real plural forms in every language, and
/// keys the code looks up resolve to text, not to the raw key.
final class R11PluralsTests: XCTestCase {

    /// The app bundle's `<lang>.lproj` — the compiled string catalog.
    private func bundle(_ lang: String) throws -> Bundle {
        let app = Bundle(for: AppViewModel.self)
        let path = try XCTUnwrap(app.path(forResource: lang, ofType: "lproj"), "no \(lang).lproj in the app bundle")
        return try XCTUnwrap(Bundle(path: path))
    }

    /// Looks the value up the way the app does for a user whose app
    /// language is `lang` (strings from that lproj, plural rules of that
    /// locale).
    private func text(_ value: String.LocalizationValue, _ lang: String) throws -> String {
        String(localized: value, bundle: try bundle(lang), locale: Locale(identifier: lang))
    }

    func test_R11_transactionCount_russianPluralForms() throws {
        XCTAssertEqual(try text("analytics.transactionsCount.\(1)", "ru"), "1 операция")
        XCTAssertEqual(try text("analytics.transactionsCount.\(3)", "ru"), "3 операции")
        XCTAssertEqual(try text("analytics.transactionsCount.\(5)", "ru"), "5 операций")
        XCTAssertEqual(try text("analytics.transactionsCount.\(21)", "ru"), "21 операция")
    }

    func test_R11_transactionCount_englishAndSpanish() throws {
        XCTAssertEqual(try text("analytics.transactionsCount.\(1)", "en"), "1 transaction")
        XCTAssertEqual(try text("analytics.transactionsCount.\(2)", "en"), "2 transactions")
        XCTAssertEqual(try text("analytics.transactionsCount.\(1)", "es"), "1 operación")
        XCTAssertEqual(try text("analytics.transactionsCount.\(4)", "es"), "4 operaciones")
    }

    func test_R11_activeDeposits_noMoreSlashForms() throws {
        XCTAssertEqual(try text("deposit.countActive \(1)", "ru"), "1 вклад")
        XCTAssertEqual(try text("deposit.countActive \(2)", "ru"), "2 вклада")
        XCTAssertEqual(try text("deposit.countActive \(11)", "ru"), "11 вкладов")
        XCTAssertEqual(try text("deposit.countActive \(1)", "en"), "1 active deposit")
    }

    func test_R11_goalDetail_pluralAndTranslated() throws {
        XCTAssertEqual(try text("savings.detail.daysToDeadline \(1)", "ru"), "1 день до дедлайна")
        XCTAssertEqual(try text("savings.detail.daysToDeadline \(4)", "ru"), "4 дня до дедлайна")
        XCTAssertEqual(try text("savings.detail.daysToDeadline \(7)", "en"), "7 days to the deadline")
        XCTAssertEqual(try text("savings.detail.ofTarget \("1 000 ₽")", "es"), "de 1 000 ₽")
        XCTAssertEqual(try text("savings.history", "es"), "Historial de operaciones")
    }

    /// The keys the review found rendering raw (`import.transactions.12`,
    /// `subscriptions.autoMatch.body Netflix`, Spanish `common.error`).
    func test_R6_previouslyRawKeys_resolveInEveryLanguage() throws {
        let rawPrefixes = ["import.", "subscriptions.", "assistant.", "feedback.", "common."]
        for lang in ["ru", "en", "es"] {
            let samples = [
                try text("import.transactions.\(12)", lang),
                try text("import.importCount.\(3)", lang),
                try text("import.imported.\(3)", lang),
                try text("import.skipped.\(2)", lang),
                try text("subscriptions.autoMatch.body \("Netflix")", lang),
                try text("assistant.micError", lang),
                try text("feedback.thanks", lang),
                try text("common.error", lang),
                try text("common.ok", lang),
            ]
            for sample in samples {
                XCTAssertFalse(rawPrefixes.contains { sample.hasPrefix($0) }, "\(lang): \(sample)")
            }
        }
        XCTAssertEqual(try text("subscriptions.autoMatch.body \("Netflix")", "ru"),
                       "Транзакция связана с подпиской «Netflix».")
        XCTAssertEqual(try text("import.importCount.\(5)", "ru"), "Импортировать 5 операций")
    }

    /// Permission prompts are localized (InfoPlist.xcstrings).
    func test_R11_permissionPrompts_localized() throws {
        let camera = try bundle("ru").localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(camera.hasPrefix("Akifi использует камеру"), camera)
        let mic = try bundle("es").localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(mic.hasPrefix("Akifi usa el micrófono"), mic)
    }
}
