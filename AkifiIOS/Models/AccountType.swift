import Foundation

/// Classifies a user account. Mirrors the `accounts.account_type` CHECK
/// constraint (migration `20260419160000_account_type.sql`).
///
/// Deposit/investment are financial instruments with automated interest
/// accrual — they're backed by a 1:1 row in the `deposits` (and future
/// `investments`) table. Transfer mechanics and Net Worth aggregation work
/// identically to plain checking accounts.
enum AccountType: String, Codable, Sendable, CaseIterable, Hashable {
    case checking
    case savings
    case cash
    case deposit
    case investment

    /// SF Symbol per case — used in pickers and list chrome.
    var icon: String {
        switch self {
        case .checking:   return "creditcard.fill"
        case .savings:    return "banknote.fill"
        case .cash:       return "dollarsign.circle.fill"
        case .deposit:    return "percent"
        case .investment: return "chart.line.uptrend.xyaxis"
        }
    }

    /// Localized user-facing title (RU/EN/ES via xcstrings).
    var localizedTitle: String {
        switch self {
        case .checking:   return String(localized: "account.type.checking")
        case .savings:    return String(localized: "account.type.savings")
        case .cash:       return String(localized: "account.type.cash")
        case .deposit:    return String(localized: "account.type.deposit")
        case .investment: return String(localized: "account.type.investment")
        }
    }
}
