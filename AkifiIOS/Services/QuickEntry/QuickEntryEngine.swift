import Foundation

/// What the user set by hand in the quick-entry sheet. Each set field wins
/// over the phrase, the prediction and the defaults.
struct QuickEntryOverrides: Equatable, Sendable {
    enum CategoryChoice: Equatable, Sendable {
        /// Use the prediction when it is confident enough.
        case automatic
        /// The user chose "no category".
        case none
        case category(String)
    }

    var type: TransactionType?
    var amount: Decimal?
    var currencyCode: String?
    var accountId: String?
    var category: CategoryChoice = .automatic
    var date: Date?
    var description: String?

    init(
        type: TransactionType? = nil,
        amount: Decimal? = nil,
        currencyCode: String? = nil,
        accountId: String? = nil,
        category: CategoryChoice = .automatic,
        date: Date? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.amount = amount
        self.currencyCode = currencyCode
        self.accountId = accountId
        self.category = category
        self.date = date
        self.description = description
    }
}

/// A transaction ready to review / save. A pure function of
/// (phrase, mode, overrides, context, clock) — recompute it on every
/// keystroke or chip tap instead of mutating it.
struct QuickEntryDraft: Equatable, Sendable {
    /// Where a field's value came from — the UI can mark guessed fields.
    enum Source: String, Equatable, Sendable {
        /// The user set it in the sheet.
        case user
        /// The phrase said it.
        case text
        /// Predicted from history.
        case history
        /// Nothing said it — default rule.
        case fallback
    }

    var type: TransactionType
    /// Main units of `currencyCode`; nil until the phrase / user gives one.
    var amount: Decimal?
    /// Entry currency (ISO, uppercase). Equal to the account's unless the
    /// phrase or the user named another — then the save converts (ADR-001).
    var currencyCode: String
    var accountId: String?
    var date: Date
    var description: String
    var categoryId: String?
    /// Ranked categories for chips, best first (same type as the draft).
    var suggestions: [QuickEntryCategorySuggestion]
    /// The parsed phrase the draft was built from.
    var parse: QuickEntryParse

    var typeSource: Source
    var amountSource: Source
    var currencySource: Source
    var accountSource: Source
    var dateSource: Source
    var categorySource: Source

    /// Amount > 0 and an account to book it on.
    var isReadyToSave: Bool {
        (amount ?? 0) > 0 && accountId != nil && type != .transfer
    }
}

/// Entry point of the quick-entry engine (phase A of 1.6.0's «быстрый
/// ввод»): phrase → draft with defaults and a predicted category.
///
/// ```swift
/// let context = QuickEntryContext(dataStore: dataStore)
/// let draft = QuickEntryEngine.draft(text: "кофе 300", context: context)
/// // draft.amount == 300, draft.categoryId == "Кафе" (from history),
/// // draft.accountId == last-used account, draft.currencyCode == its currency
/// try await QuickEntrySubmitter(dataStore: dataStore, currencyManager: cm).submit(draft)
/// ```
enum QuickEntryEngine {

    static func draft(
        text: String,
        mode: TransactionType? = nil,
        overrides: QuickEntryOverrides = QuickEntryOverrides(),
        context: QuickEntryContext,
        now: Date = Date()
    ) -> QuickEntryDraft {
        let parse = QuickEntryParser.parse(text, vocabulary: context.vocabulary, now: now, calendar: context.calendar)
        return draft(parse: parse, mode: mode, overrides: overrides, context: context, now: now)
    }

    static func draft(
        parse: QuickEntryParse,
        mode: TransactionType? = nil,
        overrides: QuickEntryOverrides = QuickEntryOverrides(),
        context: QuickEntryContext,
        now: Date = Date()
    ) -> QuickEntryDraft {
        let description = overrides.description ?? parse.description

        // Type: the user > «+» / «-» > «добавь расход» > the mode the sheet
        // was opened in > keywords > a category named in the phrase > how
        // this text was entered before > expense.
        let type: TransactionType
        let typeSource: QuickEntryDraft.Source
        let validMode = mode.flatMap { $0 == .transfer ? nil : $0 }
        let hintTypes = Set(parse.categoryHints.map(\.type))
        if let t = overrides.type, t != .transfer {
            (type, typeSource) = (t, .user)
        } else if let t = parse.signType {
            (type, typeSource) = (t, .text)
        } else if let t = parse.commandType {
            (type, typeSource) = (t, .text)
        } else if let t = validMode {
            (type, typeSource) = (t, .user)
        } else if let t = parse.keywordType {
            (type, typeSource) = (t, .text)
        } else if hintTypes.count == 1, let only = hintTypes.first {
            (type, typeSource) = (only == .income ? .income : .expense, .text)
        } else if let t = QuickEntryPredictor.historyType(for: description, context: context), t != .transfer {
            (type, typeSource) = (t, .history)
        } else {
            (type, typeSource) = (.expense, .fallback)
        }

        // Account.
        let account: Account?
        let accountSource: QuickEntryDraft.Source
        if let id = overrides.accountId, let acc = context.account(id) {
            (account, accountSource) = (acc, .user)
        } else if let id = parse.account?.accountId, let acc = context.account(id) {
            (account, accountSource) = (acc, .text)
        } else {
            (account, accountSource) = (QuickEntryDefaults.defaultAccount(for: type, context: context), .fallback)
        }

        // Currency: explicit beats the account's own.
        let currency: String
        let currencySource: QuickEntryDraft.Source
        if let c = overrides.currencyCode {
            (currency, currencySource) = (c.uppercased(), .user)
        } else if let c = parse.currencyCode {
            (currency, currencySource) = (c.uppercased(), .text)
        } else {
            (currency, currencySource) = (QuickEntryDefaults.currency(for: account, context: context), .fallback)
        }

        let amount = overrides.amount ?? parse.amount
        let amountSource: QuickEntryDraft.Source = overrides.amount != nil ? .user : (parse.amount != nil ? .text : .fallback)

        let date = overrides.date ?? parse.date ?? QuickEntryDefaults.defaultDate(now: now)
        let dateSource: QuickEntryDraft.Source = overrides.date != nil ? .user : (parse.date != nil ? .text : .fallback)

        let suggestions = QuickEntryPredictor.rankCategories(
            text: description,
            type: type,
            accountId: account?.id,
            entryDate: date,
            nameHints: parse.categoryHints,
            context: context,
            now: now
        )

        let categoryId: String?
        let categorySource: QuickEntryDraft.Source
        switch overrides.category {
        case .category(let id):
            // A pick of the other type (the user switched type afterwards)
            // does not carry over.
            if let cat = context.displayCategory(id), cat.type.rawValue == type.rawValue {
                (categoryId, categorySource) = (cat.id, .user)
            } else {
                (categoryId, categorySource) = (nil, .user)
            }
        case .none:
            (categoryId, categorySource) = (nil, .user)
        case .automatic:
            if let top = suggestions.first, top.confidence >= QuickEntryPredictor.autoApplyThreshold {
                (categoryId, categorySource) = (top.categoryId, top.reason == .categoryName ? .text : .history)
            } else {
                (categoryId, categorySource) = (nil, .fallback)
            }
        }

        return QuickEntryDraft(
            type: type,
            amount: amount,
            currencyCode: currency,
            accountId: account?.id,
            date: date,
            description: description,
            categoryId: categoryId,
            suggestions: suggestions,
            parse: parse,
            typeSource: typeSource,
            amountSource: amountSource,
            currencySource: currencySource,
            accountSource: accountSource,
            dateSource: dateSource,
            categorySource: categorySource
        )
    }

    /// The draft for a one-tap repeat (date = now).
    static func draft(repeating item: QuickEntryRepeatItem, context: QuickEntryContext, now: Date = Date()) -> QuickEntryDraft {
        draft(text: "", mode: item.type, overrides: item.overrides, context: context, now: now)
    }

    /// Strings that help speech recognition hear this user's words: account
    /// and category names plus recent descriptions.
    static func contextualStrings(context: QuickEntryContext, limit: Int = 100) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        func add(_ s: String) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 40, seen.insert(trimmed.lowercased()).inserted else { return }
            out.append(trimmed)
        }
        context.accounts.forEach { add($0.name) }
        context.displayCategories.forEach { add($0.name) }
        for item in context.history where item.isOwn {
            guard out.count < limit else { break }
            add(item.text)
        }
        return Array(out.prefix(limit))
    }
}
