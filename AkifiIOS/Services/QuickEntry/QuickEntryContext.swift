import Foundation

/// One past income / expense as the quick-entry engine sees it.
///
/// Transfers and auto-transfer legs are not history: they never carry a
/// category the user picked.
struct QuickEntryHistoryItem: Sendable, Equatable {
    let transactionId: String
    /// Written by the signed-in user (not a partner on a shared account).
    let isOwn: Bool
    let type: TransactionType
    let accountId: String?
    /// The DISPLAY category (see `QuickEntryContext.displayCategoryId`),
    /// nil when the row has none or it is hidden without a visible twin.
    let categoryId: String?
    /// Description as typed (or the merchant when there is none), trimmed.
    let text: String
    /// `QuickEntryText.identityKey` of the description / merchant.
    let identity: String
    let merchantIdentity: String?
    let keys: [String]
    /// ADR-001: kopecks in the ACCOUNT currency.
    let amountNative: Int64
    /// What the user typed when it was a foreign currency (main units).
    let foreignAmount: Decimal?
    let foreignCurrency: String?
    /// Local calendar day of the row.
    let day: Date?
    /// Local hour of the row; nil for date-only legacy rows.
    let hour: Int?
}

/// Immutable snapshot of what the quick-entry engine reads — accounts,
/// the categories a picker shows, and the user's history. Build it once
/// per sheet presentation (or when the data store changes), then call the
/// engine for every keystroke.
///
/// Category rules mirror `DataStore.displayCategories`: hidden categories
/// are never suggested, and partner duplicates from shared accounts
/// collapse onto the one display category with the same name and type.
struct QuickEntryContext: Sendable {
    let accounts: [Account]
    /// Active, deduplicated — exactly what the category pickers show.
    let displayCategories: [Category]
    let currentUserId: String?
    /// Currency for an entry without any account (ISO, uppercase).
    let fallbackCurrency: String
    /// Newest first.
    let history: [QuickEntryHistoryItem]
    let vocabulary: QuickEntryVocabulary
    /// Any category id (hidden, partner duplicate, …) → display category id.
    let displayCategoryIdById: [String: String]
    let accountsById: [String: Account]
    let calendar: Calendar

    init(
        accounts: [Account],
        categories: [Category],
        displayCategories: [Category],
        transactions: [Transaction],
        currentUserId: String?,
        fallbackCurrency: String,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) {
        self.accounts = accounts
        self.displayCategories = displayCategories
        self.currentUserId = currentUserId
        self.fallbackCurrency = fallbackCurrency.uppercased()
        self.calendar = calendar
        self.accountsById = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var displayByKey: [String: String] = [:]
        for cat in displayCategories { displayByKey[Self.dedupKey(cat)] = cat.id }
        var mapping: [String: String] = [:]
        for cat in displayCategories { mapping[cat.id] = cat.id }
        for cat in categories where mapping[cat.id] == nil {
            if let display = displayByKey[Self.dedupKey(cat)] { mapping[cat.id] = display }
        }
        self.displayCategoryIdById = mapping

        self.vocabulary = QuickEntryVocabulary(accounts: accounts, categories: displayCategories)
        self.history = Self.buildHistory(
            transactions: transactions,
            mapping: mapping,
            currentUserId: currentUserId,
            calendar: calendar
        )
    }

    /// Snapshot of the live store. `displayCategories` comes from the store
    /// itself, so the rules can't drift from what the pickers show.
    @MainActor
    init(dataStore: DataStore, currencyManager: CurrencyManager? = nil) {
        self.init(
            accounts: dataStore.accounts,
            categories: dataStore.categories,
            displayCategories: dataStore.displayCategories,
            transactions: dataStore.transactions,
            currentUserId: dataStore.profile?.id,
            fallbackCurrency: (currencyManager ?? dataStore.currencyManager)?.dataCurrency.code ?? "RUB"
        )
    }

    /// Same key as `DataStore.displayCategories` dedups on.
    static func dedupKey(_ cat: Category) -> String {
        "\(cat.name.lowercased().trimmingCharacters(in: .whitespaces))_\(cat.type.rawValue)"
    }

    func account(_ id: String?) -> Account? {
        id.flatMap { accountsById[$0] }
    }

    /// The display category for `id`, nil when it's hidden or unknown.
    func displayCategory(_ id: String?) -> Category? {
        guard let id, let displayId = displayCategoryIdById[id] else { return nil }
        return displayCategories.first { $0.id == displayId }
    }

    func displayCategories(for type: TransactionType) -> [Category] {
        displayCategories.filter { $0.type.rawValue == type.rawValue }
    }

    private static func buildHistory(
        transactions: [Transaction],
        mapping: [String: String],
        currentUserId: String?,
        calendar: Calendar
    ) -> [QuickEntryHistoryItem] {
        let rows = transactions.filter { !$0.isTransfer && ($0.type == .expense || $0.type == .income) }
        let ordered = rows.sorted { a, b in
            let da = String(a.rawDateTime.prefix(19)), db = String(b.rawDateTime.prefix(19))
            if da != db { return da > db }
            return (a.createdAt ?? "") > (b.createdAt ?? "")
        }
        return ordered.map { tx in
            let description = (tx.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let merchant = (tx.merchantName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = description.isEmpty ? merchant : description
            return QuickEntryHistoryItem(
                transactionId: tx.id,
                isOwn: currentUserId == nil || tx.userId == currentUserId,
                type: tx.type,
                accountId: tx.accountId,
                categoryId: tx.categoryId.flatMap { mapping[$0] },
                text: text,
                identity: QuickEntryText.identityKey(text),
                merchantIdentity: merchant.isEmpty ? nil : QuickEntryText.identityKey(merchant),
                keys: QuickEntryText.matchKeys(text),
                amountNative: tx.amountNative,
                foreignAmount: tx.foreignAmount,
                foreignCurrency: tx.foreignCurrency,
                day: AppDateFormatters.day(tx.date, calendar: calendar),
                hour: Self.hour(of: tx.rawDateTime)
            )
        }
    }

    /// Local hour of a stored wall-clock timestamp («2026-11-17T08:30:00…»).
    static func hour(of raw: String) -> Int? {
        let chars = Array(raw)
        guard chars.count >= 13, chars[10] == "T" || chars[10] == " ",
              let h = Int(String(chars[11...12])), (0...23).contains(h) else { return nil }
        return h
    }
}
