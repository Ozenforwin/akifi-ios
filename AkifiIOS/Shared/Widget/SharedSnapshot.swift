import Foundation

/// Lightweight snapshot of key financial metrics, written by the main app
/// to the App Group container and read by widget providers.
///
/// JSON-codable, no SwiftUI/UIKit dependency — compiles into both the app
/// target and the widget extension target (see `project.yml`).
///
/// # Versioning
/// `schemaVersion` is bumped whenever the layout changes. The store reads
/// `oldestReadableSchemaVersion...currentSchemaVersion`; anything else
/// (a newer app's payload after a downgrade, garbage) is treated as stale and
/// every widget renders its empty state — never a crash, never made-up data.
///
/// - v1: totals, daily limit, streak, today.
/// - v2 (1.6.0): per-account data (`accounts`, `monthKey`) for the «Счёт»
///   widget and «Повторить» items (`repeatItems`) for «Быстрая запись».
///   Additive and optional, so a v1 file left from 1.5.x still decodes: the
///   old widgets keep their numbers and the new ones show «Откройте Akifi»
///   until the app writes v2.
struct SharedSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2
    static let oldestReadableSchemaVersion = 1

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
    var dailyLimit: Int64?
    let dailyLimitBudgetName: String?
    /// Already spent today against that same budget, base-currency kopecks.
    var dailySpentToday: Int64
    /// Utilization 0–999 (see `BudgetMath.computeProgress`). Widget uses it
    /// to colour the ring (green / amber / red) without re-running math.
    let dailyLimitUtilization: Int

    // MARK: Streak widget
    let currentStreak: Int
    /// Next unreached `StreakTracker.milestones` value. Equal to the highest
    /// milestone (`365`) once a user has crossed them all.
    let nextMilestone: Int

    // MARK: Day Summary widget
    var todayIncome: Int64
    var todayExpense: Int64
    /// income - expense for today.
    var todayNet: Int64

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

    // MARK: Accounts (v2) — optional, so v1 payloads still decode.
    /// The user's MONEY accounts (`DataStore.accounts` — never a «Долги»
    /// account), in the app's order. nil = a v1 payload without account
    /// data; [] = signed in without accounts.
    var accounts: [AccountItem]? = nil
    /// "yyyy-MM" (device zone, Gregorian) the accounts' month income /
    /// expense belong to. nil = unknown (gallery sample) → never rolled over.
    var monthKey: String? = nil
    /// Top «Повторить» items (`QuickEntryPredictor.repeatCandidates`) for
    /// the «Быстрая запись» widget. nil in v1 payloads.
    var repeatItems: [RepeatItem]? = nil

    /// One money account as the «Счёт» widget shows it. Every amount is in
    /// THIS account's own currency (ADR-001: `amount_native`), minor units
    /// ×100 like the rest of the app — never converted.
    struct AccountItem: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        /// Emoji of the icon tile.
        let icon: String
        /// The account colour as stored ("#3B82F6").
        let colorHex: String
        let currencyCode: String
        let currencySymbol: String
        /// Fraction digits to show (0 for RUB, 2 for USD).
        let currencyDecimals: Int
        /// `DataStore.nativeBalance(for:)`.
        let balance: Int64
        /// This month's income / expense on the account (transfers and debt
        /// movements excluded), same currency as `balance`.
        var monthIncome: Int64
        var monthExpense: Int64
        let isPrimary: Bool
        let isShared: Bool
        /// The eye toggle on the Home card: the widget shows «••••».
        let isBalanceHidden: Bool
    }

    /// One «Повторить» entry: display data and the quick-add link that
    /// opens the sheet prefilled with it (it never saves by itself).
    struct RepeatItem: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let isIncome: Bool
        /// Description, else the category's name, else the type.
        let title: String
        /// Category emoji.
        let icon: String?
        /// «300 ₽» in the entry currency, formatted by the app.
        let amountText: String
        let accountName: String?
        /// `akifi://quick-add?…` built by `QuickEntryLaunchLink`.
        let url: String
    }

    /// What a widget shows (Y7): the snapshot the app wrote, or nothing —
    /// the explicit «Откройте Akifi» state (signed out, fresh install,
    /// unreadable payload). The sample numbers of `placeholder` are for
    /// the widget gallery only; on a home screen they read as the user's
    /// own money («125 000 ₽ на 3 счетах» after a sign-out).
    static func forDisplay(stored: SharedSnapshot?, isPreview: Bool) -> SharedSnapshot? {
        stored ?? (isPreview ? placeholder : nil)
    }

    /// Sample data for the widget gallery (`placeholder(in:)`,
    /// `context.isPreview`) — never shown in place of real data.
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
        netWorth: 325_000_00,
        accounts: [
            AccountItem(
                id: "00000000-0000-4000-8000-000000000001",
                name: String(localized: "widget.sample.account", defaultValue: "Карта"),
                icon: "💳", colorHex: "#3B82F6",
                currencyCode: "RUB", currencySymbol: "₽", currencyDecimals: 0,
                balance: 84_250_00, monthIncome: 120_000_00, monthExpense: 46_380_00,
                isPrimary: true, isShared: false, isBalanceHidden: false
            )
        ],
        repeatItems: [
            RepeatItem(id: "sample-1", isIncome: false,
                       title: String(localized: "widget.sample.coffee", defaultValue: "Кофе"),
                       icon: "☕️", amountText: "250 ₽", accountName: nil,
                       url: "akifi://quick-add?mode=expense&source=widget"),
            RepeatItem(id: "sample-2", isIncome: false,
                       title: String(localized: "widget.sample.groceries", defaultValue: "Продукты"),
                       icon: "🛒", amountText: "1 840 ₽", accountName: nil,
                       url: "akifi://quick-add?mode=expense&source=widget"),
            RepeatItem(id: "sample-3", isIncome: false,
                       title: String(localized: "widget.sample.taxi", defaultValue: "Такси"),
                       icon: "🚕", amountText: "420 ₽", accountName: nil,
                       url: "akifi://quick-add?mode=expense&source=widget")
        ]
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
    /// left in the budget window (today included). In a new month the
    /// accounts' month income / expense drop to zero the same way. Every
    /// other field (balances, «Повторить», …) is kept as written. Same day →
    /// unchanged.
    func rolledOver(to date: Date, calendar: Calendar = SharedSnapshot.dayCalendar) -> SharedSnapshot {
        let today = Self.dayKey(for: date, calendar: calendar)
        guard today != effectiveDayKey else { return self }

        var limit = dailyLimit
        if let leftover = dailyLimitLeftover, let endKey = dailyLimitPeriodEnd,
           let end = Self.date(fromDayKey: endKey, calendar: calendar) {
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: end).day ?? -1) + 1
            if days > 0 { limit = max(0, leftover / Int64(days)) }
        }

        // A copy, so fields added later survive the rollover by default.
        var copy = self
        copy.dailyLimit = limit
        copy.dailySpentToday = 0
        copy.todayIncome = 0
        copy.todayExpense = 0
        copy.todayNet = 0
        copy.dayKey = today

        let month = String(today.prefix(7))
        if let stored = monthKey, stored != month {
            copy.accounts = accounts?.map { item in
                var item = item
                item.monthIncome = 0
                item.monthExpense = 0
                return item
            }
            copy.monthKey = month
        }
        return copy
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
