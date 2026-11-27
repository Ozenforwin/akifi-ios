import Foundation

/// Why a quick-entry draft can't be saved.
enum QuickEntrySubmitError: LocalizedError, Equatable {
    case missingAmount
    case missingAccount
    /// The account is gone (deleted on another device meanwhile).
    case unknownAccount
    /// The category belongs to the other type or is hidden.
    case invalidCategory
    case unsupportedType

    var errorDescription: String? {
        switch self {
        case .missingAmount: String(localized: "transaction.invalidAmount")
        case .missingAccount, .unknownAccount: String(localized: "quickEntry.error.noAccount")
        case .invalidCategory: String(localized: "quickEntry.error.category")
        case .unsupportedType: String(localized: "quickEntry.error.type")
        }
    }
}

/// The one write path of quick entry — the sheet, Siri and Shortcuts all
/// save through it, and it saves exactly like `TransactionFormView` does
/// for a new expense / income:
///
/// - `user_id` from the live session (`SupabaseManager.currentUserId`),
///   never the cached profile — a stale one fails RLS;
/// - ADR-001: `amount_native` in the ACCOUNT currency; a foreign entry is
///   converted with a recent real rate (`CurrencyManager.ratesForWrite`)
///   and kept in `foreign_amount` / `foreign_currency` / `fx_rate`
///   (`TransactionFormView.entryAmounts`, which refuses a missing rate);
/// - written by `DataStore.addTransaction` — online insert or the offline
///   queue, session-epoch checks, cache, widget snapshot, auto-match;
/// - no payment source: new entries start as a plain expense on the
///   account, like the form (the «Оплачено с» default is never
///   auto-applied).
@MainActor
struct QuickEntrySubmitter {
    let dataStore: DataStore
    let currencyManager: CurrencyManager?
    /// Session seam — tests replace it.
    var userId: @MainActor () async throws -> String = {
        try await SupabaseManager.shared.currentUserId()
    }
    /// Rate seam — tests replace it. Production: real quotes < 48 h old.
    var rates: @MainActor ([String]) async -> [String: Double]

    init(dataStore: DataStore, currencyManager: CurrencyManager? = nil) {
        self.dataStore = dataStore
        let cm = currencyManager ?? dataStore.currencyManager
        self.currencyManager = cm
        self.rates = { codes in
            guard let cm else { return [:] }
            return await cm.ratesForWrite(codes)
        }
    }

    /// The large-expense guard of the form, for the sheet's confirmation
    /// and Siri's «are you sure?» (same rule: far above the usual expense).
    func largeExpenseDecision(for draft: QuickEntryDraft) -> TransactionGuards.LargeExpenseDecision? {
        guard let amount = draft.amount, amount > 0 else { return nil }
        return TransactionGuards.shouldConfirmLargeExpense(
            inputAmount: amount,
            inputCurrency: draft.currencyCode,
            type: draft.type,
            allTransactions: dataStore.transactions,
            context: dataStore.currencyContext
        )
    }

    /// Saves `draft`. Returns the stored (or queued) transaction.
    @discardableResult
    func submit(_ draft: QuickEntryDraft) async throws -> Transaction {
        let account = try validatedAccount(for: draft)
        let accountCurrency = account.currency.uppercased()
        let entryCurrency = draft.currencyCode.uppercased()
        let rates = entryCurrency == accountCurrency ? [:] : await rates([entryCurrency, accountCurrency])
        let userId = try await userId()
        let input = try Self.makeInput(draft: draft, account: account, userId: userId, rates: rates, categories: dataStore.displayCategories)
        return try await dataStore.addTransaction(input)
    }

    private func validatedAccount(for draft: QuickEntryDraft) throws -> Account {
        guard draft.type == .expense || draft.type == .income else { throw QuickEntrySubmitError.unsupportedType }
        guard let amount = draft.amount, amount > 0 else { throw QuickEntrySubmitError.missingAmount }
        guard let accountId = draft.accountId else { throw QuickEntrySubmitError.missingAccount }
        guard let account = dataStore.accounts.first(where: { $0.id == accountId }) else {
            throw QuickEntrySubmitError.unknownAccount
        }
        return account
    }

    /// Pure core: the insert for `draft` on `account`.
    nonisolated static func makeInput(
        draft: QuickEntryDraft,
        account: Account,
        userId: String,
        rates: [String: Double],
        categories: [Category]
    ) throws -> CreateTransactionInput {
        guard draft.type == .expense || draft.type == .income else { throw QuickEntrySubmitError.unsupportedType }
        guard let raw = draft.amount, raw > 0 else { throw QuickEntrySubmitError.missingAmount }
        let entryCurrency = draft.currencyCode.uppercased()
        let accountCurrency = account.currency.uppercased()
        // What can be stored in the entry currency (VND whole dong, …).
        let amount = MoneyRounding.roundedForStorage(raw, currency: entryCurrency)
        guard amount > 0 else { throw QuickEntrySubmitError.missingAmount }

        if let categoryId = draft.categoryId {
            guard let category = categories.first(where: { $0.id == categoryId }),
                  category.type.rawValue == draft.type.rawValue else {
                throw QuickEntrySubmitError.invalidCategory
            }
        }

        let entry = try TransactionFormView.entryAmounts(
            amount: amount,
            entryCurrency: entryCurrency,
            accountCurrency: accountCurrency,
            rates: rates
        )
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateTransactionInput(
            user_id: userId,
            account_id: account.id,
            amount: entry.native,
            amount_native: entry.native,
            currency: accountCurrency,
            foreign_amount: entry.foreignAmount,
            foreign_currency: entry.foreignCurrency,
            fx_rate: entry.fxRate,
            type: draft.type.rawValue,
            date: TransactionFormDates.string(from: draft.date),
            description: description.isEmpty ? nil : description,
            category_id: draft.categoryId,
            merchant_name: nil
        )
    }
}
