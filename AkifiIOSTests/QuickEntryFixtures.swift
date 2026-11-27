import Foundation
@testable import AkifiIOS

/// Shared fixtures of the quick-entry tests: a fixed clock (Friday
/// 2026-11-27 14:30, Moscow), accounts, categories and history rows.
enum QE {
    static let timeZone = TimeZone(identifier: "Europe/Moscow")!
    static let calendar = AppDateFormatters.gregorian(timeZone: timeZone)
    static let me = "u-me"
    static let partner = "u-partner"

    /// Friday, 27 November 2026, 14:30 Moscow.
    static let now = date(2026, 11, 27, 14, 30)

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// `yyyy-MM-dd` of `date` in the fixture time zone.
    static func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        return AppDateFormatters.localDate(in: timeZone).string(from: date)
    }

    static func account(
        _ id: String,
        _ name: String,
        currency: String = "RUB",
        type: AccountType = .checking,
        primary: Bool = false,
        userId: String = me
    ) -> Account {
        Account(id: id, userId: userId, name: name, icon: "💳", color: "#3B82F6",
                initialBalance: 0, isPrimary: primary, currency: currency, accountType: type)
    }

    static func category(
        _ id: String,
        _ name: String,
        _ type: CategoryType = .expense,
        userId: String = me,
        active: Bool = true,
        createdAt: String = "2026-01-01T00:00:00Z"
    ) -> AkifiIOS.Category {
        AkifiIOS.Category(id: id, userId: userId, accountId: nil, name: name, icon: "🏷", color: "#000000",
                          type: type, isActive: active, createdAt: createdAt)
    }

    /// A history row. `raw` is the stored local wall-clock timestamp.
    static func tx(
        _ id: String,
        _ description: String?,
        amount kopecks: Int64,
        category: String?,
        account: String = "acc-card",
        type: TransactionType = .expense,
        raw: String,
        userId: String = me,
        merchant: String? = nil,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        transferGroupId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: userId, accountId: account, amount: kopecks, amountNative: kopecks,
            currency: "RUB", foreignAmount: foreignAmount, foreignCurrency: foreignCurrency, fxRate: nil,
            description: description, categoryId: category, type: type,
            date: String(raw.prefix(10)), rawDateTime: raw, merchantName: merchant, merchantFuzzy: nil,
            transferGroupId: transferGroupId, status: nil, createdAt: raw, updatedAt: nil
        )
    }

    static let card = account("acc-card", "Тинькофф", primary: true)
    static let cash = account("acc-cash", "Кошелёк", type: .cash)
    static let usd = account("acc-usd", "ByBit", currency: "USD", type: .investment)
    static let deposit = account("acc-dep", "Вклад", type: .deposit)
    static let sber = account("acc-sber", "Сбер")

    static let cafe = category("cat-cafe", "Кафе")
    static let groceries = category("cat-food", "Продукты")
    static let taxi = category("cat-taxi", "Такси")
    static let restaurants = category("cat-rest", "Кафе и рестораны")
    static let salary = category("cat-salary", "Зарплата", .income)
    static let gifts = category("cat-gifts", "Подарки", .income)

    static func context(
        accounts: [Account] = [card, cash, usd, deposit, sber],
        categories: [AkifiIOS.Category] = [cafe, groceries, taxi, salary, gifts],
        display: [AkifiIOS.Category]? = nil,
        transactions: [Transaction] = [],
        currentUserId: String? = me,
        fallbackCurrency: String = "RUB"
    ) -> QuickEntryContext {
        QuickEntryContext(
            accounts: accounts,
            categories: categories,
            displayCategories: display ?? categories.filter(\.isActive),
            transactions: transactions,
            currentUserId: currentUserId,
            fallbackCurrency: fallbackCurrency,
            calendar: calendar
        )
    }

    static func parse(_ text: String, vocabulary: QuickEntryVocabulary = .empty) -> QuickEntryParse {
        QuickEntryParser.parse(text, vocabulary: vocabulary, now: now, calendar: calendar)
    }

    static let vocabulary = QuickEntryVocabulary(
        accounts: [card, cash, usd, deposit, sber],
        categories: [cafe, groceries, taxi, restaurants, salary, gifts]
    )
}
