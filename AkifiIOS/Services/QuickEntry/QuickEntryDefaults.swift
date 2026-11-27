import Foundation

/// Defaults for what a quick entry doesn't say.
///
/// - Account: the account the user last booked an entry of this type on,
///   among accounts that take everyday entries (not a deposit); otherwise
///   the primary account; otherwise the first such account.
/// - Date: now. Stored as local wall-clock time (`TransactionFormDates`),
///   so the day is the user's local day (`AppDateFormatters` contract).
/// - Currency: the account's own (ADR-001) — a foreign currency only when
///   the phrase names one.
enum QuickEntryDefaults {

    /// Whether `account` may be picked without the user naming it.
    ///
    /// Exhaustive on purpose: a new account type (debts, cards with a
    /// credit limit, …) fails to compile here until someone decides
    /// whether everyday spending should land on it by default.
    static func isEligibleDefault(_ account: Account) -> Bool {
        switch account.accountType {
        case .checking, .savings, .cash, .investment:
            return true
        case .deposit, .debt, .unsupported:
            // Deposits lock money; a debt account is what a person owes
            // (1.6 «Долги»); an unknown type is hidden everywhere.
            return false
        }
    }

    static func defaultAccount(for type: TransactionType, context: QuickEntryContext) -> Account? {
        let eligible = context.accounts.filter(isEligibleDefault)
        guard !eligible.isEmpty else { return nil }
        let eligibleIds = Set(eligible.map(\.id))
        if type != .transfer,
           let last = context.history.first(where: {
               $0.isOwn && $0.type == type && $0.accountId.map(eligibleIds.contains) == true
           }),
           let account = context.account(last.accountId) {
            return account
        }
        return eligible.first(where: \.isPrimary) ?? eligible.first
    }

    static func defaultDate(now: Date = Date()) -> Date {
        now
    }

    /// Entry currency for an account (ISO, uppercase).
    static func currency(for account: Account?, context: QuickEntryContext) -> String {
        account?.currency.uppercased() ?? context.fallbackCurrency
    }
}
