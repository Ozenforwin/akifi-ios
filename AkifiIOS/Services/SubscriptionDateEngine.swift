import Foundation

/// Pure domain service for subscription date math.
///
/// All functions are side-effect free, calendar-aware, and deterministic.
/// Month overflow (e.g. 31 Jan + 1 month) is clamped by `Calendar`
/// (31 Jan + 1 month → 28/29 Feb). Leap-year 29 Feb + 1 year → 28 Feb.
///
/// Storage contract: dates are passed/returned as `Date` (start of day, local tz).
/// Callers convert to `yyyy-MM-dd` strings when persisting to Supabase.
///
/// See ADR-004-subscription-date-engine.
enum SubscriptionDateEngine {

    // MARK: - Configuration

    /// Default custom-period length when `BillingPeriod.custom` is selected
    /// and no explicit `customDays` is supplied.
    static let defaultCustomDays: Int = 30

    // MARK: - Public API

    /// Compute the next payment date given the last payment date and a billing period.
    ///
    /// - Parameters:
    ///   - lastPaymentDate: The most recent actual (or assumed) payment date.
    ///   - period: Billing period enum.
    ///   - customDays: Number of days to add when `period == .custom`. Defaults to 30.
    ///   - calendar: Calendar used for the arithmetic. Exposed for testing; defaults to `.current`.
    /// - Returns: Start-of-day `Date` of the next scheduled payment.
    static func nextPaymentDate(
        from lastPaymentDate: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = .current
    ) -> Date {
        let base = calendar.startOfDay(for: lastPaymentDate)
        let result: Date
        switch period {
        case .weekly:
            result = calendar.date(byAdding: .weekOfYear, value: 1, to: base) ?? base
        case .monthly:
            result = calendar.date(byAdding: .month, value: 1, to: base) ?? base
        case .quarterly:
            result = calendar.date(byAdding: .month, value: 3, to: base) ?? base
        case .yearly:
            result = calendar.date(byAdding: .year, value: 1, to: base) ?? base
        case .custom:
            let days = customDays ?? defaultCustomDays
            result = calendar.date(byAdding: .day, value: days, to: base) ?? base
        }
        return calendar.startOfDay(for: result)
    }

    /// Compute the previous payment date given the next payment date and a billing period.
    ///
    /// Inverse of `nextPaymentDate(from:period:customDays:calendar:)` — used when the user
    /// enters "next payment" but we need to infer "last payment" (e.g. on form open).
    static func previousPaymentDate(
        from nextPaymentDate: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = .current
    ) -> Date {
        let base = calendar.startOfDay(for: nextPaymentDate)
        let result: Date
        switch period {
        case .weekly:
            result = calendar.date(byAdding: .weekOfYear, value: -1, to: base) ?? base
        case .monthly:
            result = calendar.date(byAdding: .month, value: -1, to: base) ?? base
        case .quarterly:
            result = calendar.date(byAdding: .month, value: -3, to: base) ?? base
        case .yearly:
            result = calendar.date(byAdding: .year, value: -1, to: base) ?? base
        case .custom:
            let days = customDays ?? defaultCustomDays
            result = calendar.date(byAdding: .day, value: -days, to: base) ?? base
        }
        return calendar.startOfDay(for: result)
    }

    /// Reminder fire date: `nextPaymentDate - daysBefore` at the given hour of day.
    ///
    /// - Parameters:
    ///   - nextPaymentDate: Upcoming payment date.
    ///   - daysBefore: Non-negative days prior to the payment (0 = same day).
    ///   - hour: Local hour of day when the reminder should fire. Defaults to 9 (09:00).
    ///   - calendar: Calendar used for the arithmetic. Exposed for testing.
    /// - Returns: `Date` at `hour:00` local time on the reminder day, or `nil` if in the past.
    static func reminderFireDate(
        nextPaymentDate: Date,
        daysBefore: Int,
        hour: Int = 9,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Date? {
        let days = max(0, daysBefore)
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: nextPaymentDate)) ?? nextPaymentDate
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = 0
        guard let fire = calendar.date(from: components) else { return nil }
        return fire > now ? fire : nil
    }

    // MARK: - String helpers (date-only persistence)

    /// Canonical date-only formatter used across the app for `start_date`,
    /// `last_payment_date`, `next_payment_date` columns.
    static let dbDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    /// Parse a `yyyy-MM-dd` (or longer ISO) string into a start-of-day `Date`.
    /// Returns `nil` if unparsable.
    static func parseDbDate(_ string: String?) -> Date? {
        guard let s = string, !s.isEmpty else { return nil }
        // Accept both pure date and full ISO timestamps ("2026-04-15T09:00:00Z").
        let prefix = String(s.prefix(10))
        return dbDateFormatter.date(from: prefix)
    }

    /// Format a `Date` as `yyyy-MM-dd` for persistence.
    static func formatDbDate(_ date: Date) -> String {
        dbDateFormatter.string(from: date)
    }
}
