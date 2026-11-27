import Foundation
import os

/// Classifies a user account. Mirrors the `accounts.account_type` CHECK
/// constraint (migrations `20260419160000_account_type.sql`,
/// `20261128090000_debt_accounts.sql`).
///
/// Deposit/investment are financial instruments with automated interest
/// accrual — they're backed by a 1:1 row in the `deposits` (and future
/// `investments`) table. Transfer mechanics and Net Worth aggregation work
/// identically to plain checking accounts.
///
/// `debt` (1.6.0) is a person who owes me or whom I owe («Долги»), backed by
/// a 1:1 row in `debts`. Its balance is NOT money the user can spend — see
/// `isMoney`, the one predicate every list, picker and total goes through.
///
/// **Decoding is tolerant** (contract A8 / C1): a value this build does not
/// know maps to `.unsupported` instead of throwing. A strict enum made one
/// new `account_type` fail the whole `accounts` fetch and the offline cache
/// on every older client.
enum AccountType: String, Codable, Sendable, CaseIterable, Hashable {
    case checking
    case savings
    case cash
    case deposit
    case investment
    case debt
    /// A type a newer server sent that this build does not understand.
    /// Hidden everywhere (not money, not a debt) until an update knows it.
    case unsupported

    /// Spendable money: shown in the account carousel, every account picker,
    /// "всего на счетах", the widget, budgets, sharing, the assistant context.
    ///
    /// The `switch` is exhaustive on purpose: a new case does not compile
    /// until someone decides whether it is money.
    var isMoney: Bool {
        switch self {
        case .checking, .savings, .cash, .deposit, .investment:
            return true
        case .debt, .unsupported:
            return false
        }
    }

    /// SF Symbol per case — used in pickers and list chrome.
    var icon: String {
        switch self {
        case .checking:    return "creditcard.fill"
        case .savings:     return "banknote.fill"
        case .cash:        return "dollarsign.circle.fill"
        case .deposit:     return "percent"
        case .investment:  return "chart.line.uptrend.xyaxis"
        case .debt:        return "person.crop.circle"
        case .unsupported: return "questionmark.circle"
        }
    }

    /// Localized user-facing title (RU/EN/ES via xcstrings).
    var localizedTitle: String {
        switch self {
        case .checking:    return String(localized: "account.type.checking")
        case .savings:     return String(localized: "account.type.savings")
        case .cash:        return String(localized: "account.type.cash")
        case .deposit:     return String(localized: "account.type.deposit")
        case .investment:  return String(localized: "account.type.investment")
        case .debt:        return String(localized: "account.type.debt")
        case .unsupported: return String(localized: "account.type.unsupported")
        }
    }

    // MARK: - Tolerant decoding

    /// Maps a raw `account_type` value. Unknown → `.unsupported`, logged once
    /// per value and process.
    static func tolerant(_ raw: String) -> AccountType {
        if let known = AccountType(rawValue: raw.lowercased()) { return known }
        UnknownAccountTypeLog.noteOnce(raw)
        return .unsupported
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // A non-string (or null) is as unknown as an unknown string.
        let raw = (try? container.decode(String.self)) ?? ""
        self = AccountType.tolerant(raw)
    }
}

/// Logs each unknown `account_type` once, so a list of fifty rows of a new
/// type does not produce fifty log lines.
enum UnknownAccountTypeLog {
    private static let seen = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func noteOnce(_ raw: String) {
        let isNew = seen.withLock { $0.insert(raw).inserted }
        guard isNew else { return }
        AppLogger.data.warning("Unknown account_type '\(raw, privacy: .public)' — hidden as unsupported")
    }

    /// Values logged so far (tests).
    static var loggedValues: Set<String> { seen.withLock { $0 } }
}

extension Account {
    /// Spendable money account — see `AccountType.isMoney`.
    var isMoneyAccount: Bool { accountType.isMoney }

    /// A «Долги» account (a person).
    var isDebtAccount: Bool { accountType == .debt }
}

extension Sequence where Element == Account {
    /// The spendable subset — the source of every account list, picker and
    /// total. `DataStore.accounts` already is this; forms that receive an
    /// array apply it again so a caller passing `allAccounts` can't leak a
    /// debt into a picker.
    var moneyAccounts: [Account] { filter(\.isMoneyAccount) }
}
