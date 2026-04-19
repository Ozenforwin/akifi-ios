import Foundation

/// Lightweight snapshot of key financial metrics, written by the main app
/// to the App Group container and read by widget providers.
///
/// JSON-codable, no SwiftUI/UIKit dependency — compiles into both the app
/// target and the widget extension target (see `project.yml`).
///
/// # Versioning
/// `schemaVersion` is bumped any time the layout changes in a
/// backward-incompatible way. Widget providers must tolerate older payloads
/// by treating unknown versions as stale and rendering the placeholder.
struct SharedSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let lastUpdated: Date

    // MARK: Currency context
    let baseCurrency: String          // "RUB" / "USD" / "EUR" / ...
    let baseCurrencySymbol: String    // "₽" / "$" / "€" / ...
    let baseCurrencyDecimals: Int     // 0 for RUB/VND/THB/IDR, 2 for USD/EUR

    // MARK: Balance widget
    /// Sum of account balances normalized to base currency, in kopecks
    /// (i.e. amount * 10^baseCurrencyDecimals for 2-decimal currencies,
    /// amount * 100 as legacy Int64 minor unit throughout the app).
    let totalBalance: Int64
    let accountCount: Int

    // MARK: Daily Limit widget
    /// Safe-to-spend-today as returned by `BudgetMath.safeToSpendDaily`
    /// for the active primary budget, in base-currency kopecks.
    /// `nil` when the user has no active budget.
    let dailyLimit: Int64?
    let dailyLimitBudgetName: String?
    /// Already spent today against that same budget, base-currency kopecks.
    let dailySpentToday: Int64
    /// Utilization 0–999 (see `BudgetMath.computeProgress`). Widget uses it
    /// to colour the ring (green / amber / red) without re-running math.
    let dailyLimitUtilization: Int

    // MARK: Streak widget
    let currentStreak: Int
    /// Next unreached `StreakTracker.milestones` value. Equal to the highest
    /// milestone (`365`) once a user has crossed them all.
    let nextMilestone: Int

    // MARK: Day Summary widget
    let todayIncome: Int64
    let todayExpense: Int64
    /// income - expense for today.
    let todayNet: Int64

    // MARK: Bonus
    /// Optional net worth for a future NetWorth widget. `nil` when the
    /// user has no assets/liabilities recorded.
    let netWorth: Int64?

    /// A neutral placeholder used by widget previews and cold-start cases
    /// when the App Group container is empty.
    static let placeholder = SharedSnapshot(
        schemaVersion: currentSchemaVersion,
        lastUpdated: Date(timeIntervalSince1970: 0),
        baseCurrency: "RUB",
        baseCurrencySymbol: "₽",
        baseCurrencyDecimals: 0,
        totalBalance: 125_000_00,
        accountCount: 3,
        dailyLimit: 1_200_00,
        dailyLimitBudgetName: "Еда",
        dailySpentToday: 450_00,
        dailyLimitUtilization: 37,
        currentStreak: 12,
        nextMilestone: 14,
        todayIncome: 5_000_00,
        todayExpense: 1_250_00,
        todayNet: 3_750_00,
        netWorth: 325_000_00
    )
}
