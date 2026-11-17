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

    // MARK: Day rollover (Y11) — optional, so older payloads still decode.
    /// "yyyy-MM-dd" (device zone, Gregorian) the "today" fields belong to.
    /// `nil` in payloads written before this field: the day of
    /// `lastUpdated` is used instead.
    var dayKey: String? = nil
    /// Primary budget's leftover after subscriptions (base-currency minor
    /// units) — lets the widget re-spread the allowance over the days left
    /// after midnight without the app running.
    var dailyLimitLeftover: Int64? = nil
    /// Last day of the primary budget's window, "yyyy-MM-dd".
    var dailyLimitPeriodEnd: String? = nil

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

extension SharedSnapshot {
    /// Gregorian in the device zone — the calendar the app uses for "today".
    static var dayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    static func dayKey(for date: Date, calendar: Calendar = SharedSnapshot.dayCalendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day the "today" fields were computed for.
    var effectiveDayKey: String { dayKey ?? Self.dayKey(for: lastUpdated) }

    /// The snapshot as it should read on `date` (Y11). The app computes the
    /// "today" fields only while it runs, so after midnight they belong to
    /// yesterday: income / expense / net / spent-today drop to zero, and the
    /// daily allowance is the stored leftover re-spread over the days now
    /// left in the budget window (today included). Same day → unchanged.
    func rolledOver(to date: Date, calendar: Calendar = SharedSnapshot.dayCalendar) -> SharedSnapshot {
        let today = Self.dayKey(for: date, calendar: calendar)
        guard today != effectiveDayKey else { return self }

        var limit = dailyLimit
        if let leftover = dailyLimitLeftover, let endKey = dailyLimitPeriodEnd,
           let end = Self.date(fromDayKey: endKey, calendar: calendar) {
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: end).day ?? -1) + 1
            if days > 0 { limit = max(0, leftover / Int64(days)) }
        }

        var copy = SharedSnapshot(
            schemaVersion: schemaVersion,
            lastUpdated: lastUpdated,
            baseCurrency: baseCurrency,
            baseCurrencySymbol: baseCurrencySymbol,
            baseCurrencyDecimals: baseCurrencyDecimals,
            totalBalance: totalBalance,
            accountCount: accountCount,
            dailyLimit: limit,
            dailyLimitBudgetName: dailyLimitBudgetName,
            dailySpentToday: 0,
            dailyLimitUtilization: dailyLimitUtilization,
            currentStreak: currentStreak,
            nextMilestone: nextMilestone,
            todayIncome: 0,
            todayExpense: 0,
            todayNet: 0,
            netWorth: netWorth
        )
        copy.dayKey = today
        copy.dailyLimitLeftover = dailyLimitLeftover
        copy.dailyLimitPeriodEnd = dailyLimitPeriodEnd
        return copy
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
