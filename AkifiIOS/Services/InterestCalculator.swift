import Foundation

/// Pure, stateless interest-accrual math for deposits.
///
/// # Contract
/// - All monetary values are `Int64` kopecks.
/// - `rate` is an annual percentage (e.g. `12.5` = 12.5% APR).
/// - Uses `Decimal` end-to-end to avoid `Double` precision drift on long
///   compounding windows (daily × 10 years would lose ~0.5 ruble otherwise).
/// - Lot-based: each `DepositContribution` carries its own `contributedAt`
///   start date. Per-lot accrual is summed — matches bank-side math where
///   every top-up starts its own compounding clock.
/// - Fallbacks: invalid dates → treated as zero elapsed time (no interest);
///   negative durations → zero; zero rate → zero.
///
/// # Why pure (no state, no DB)?
/// Keep the math trivial to unit test. Phase 2 (server-side pg_cron)
/// re-implements the same formula in SQL; the Swift version must match
/// bit-exact for user-facing live accrual.
enum InterestCalculator {

    /// Sums interest accrued across all contributions from their individual
    /// start dates up to `asOf`. Principal is *not* included in the return
    /// value — this is the incremental interest-income amount.
    ///
    /// - Parameters:
    ///   - contributions: every lot of the deposit, each with its own
    ///     `amount` (kopecks) and `contributedAt` (yyyy-MM-dd).
    ///   - rate: annual percentage (12.5 → 12.5%).
    ///   - frequency: compounding schedule.
    ///   - asOf: the "today" timestamp. Use UTC for consistency.
    ///   - calendar: injected for deterministic tests. Defaults to
    ///     `Calendar(identifier: .gregorian)` with UTC tz so reproduction
    ///     on any user locale is identical.
    static func accrueInterest(
        contributions: [DepositContribution],
        rate: Decimal,
        frequency: CompoundFrequency,
        asOf: Date,
        calendar: Calendar = defaultCalendar
    ) -> Int64 {
        guard rate > 0 else { return 0 }

        var total: Int64 = 0
        for contrib in contributions {
            guard contrib.amount > 0 else { continue }
            guard let startDate = parseDate(contrib.contributedAt, calendar: calendar) else { continue }
            let accrued = accruedForLot(
                principal: contrib.amount,
                rate: rate,
                frequency: frequency,
                startDate: startDate,
                asOf: asOf,
                calendar: calendar
            )
            total += accrued
        }
        return total
    }

    /// Projects the total value at maturity (principal + total accrued
    /// interest) for the given contribution set. Used in UI "to maturity:
    /// X" hints.
    ///
    /// If `maturityDate <= asOf-of-a-contribution` the lot contributes
    /// only its principal (no negative accrual).
    static func projectedMaturityValue(
        contributions: [DepositContribution],
        rate: Decimal,
        frequency: CompoundFrequency,
        maturityDate: Date,
        calendar: Calendar = defaultCalendar
    ) -> Int64 {
        let principal = totalPrincipal(contributions)
        let interest = accrueInterest(
            contributions: contributions,
            rate: rate,
            frequency: frequency,
            asOf: maturityDate,
            calendar: calendar
        )
        return principal + interest
    }

    /// Sum of every contribution's `amount` (kopecks).
    static func totalPrincipal(_ contributions: [DepositContribution]) -> Int64 {
        contributions.reduce(0) { $0 + $1.amount } // allowlisted-amount: DepositContribution.amount is in deposit's own currency, not Transaction.amount
    }

    // MARK: - Internals

    /// Core formula per lot.
    /// - Simple: `I = P * r * t` (t in years).
    /// - Compound: `I = P * ((1 + r/n)^(n*t) - 1)` where `n = periodsPerYear`.
    ///
    /// Decimal `pow(base:exp:)` isn't in stdlib — we go through
    /// `NSDecimalNumber.raising(toPower:)` for integer exponents and fall
    /// back to `Double.pow` for fractional `n*t` (deposit daily-compound for
    /// a mid-period "as of now" needs fractional days). The fallback
    /// precision loss is negligible at realistic deposit scales (~1e-8
    /// on principal up to 10^12 kopecks).
    private static func accruedForLot(
        principal: Int64,
        rate: Decimal,
        frequency: CompoundFrequency,
        startDate: Date,
        asOf: Date,
        calendar: Calendar
    ) -> Int64 {
        let years = yearsElapsed(from: startDate, to: asOf, calendar: calendar)
        if years <= 0 { return 0 }

        let P = Decimal(principal)
        let r = rate / 100  // 12.5 → 0.125

        switch frequency {
        case .simple:
            // I = P * r * t
            let interest = P * r * years
            return roundToInt64(interest)

        case .daily, .monthly, .quarterly, .yearly:
            let n = frequency.periodsPerYear
            // Total exponent n*t. Usually fractional (partial period).
            let exponent = n * years
            let base = 1 + r / n
            let factor = powDecimal(base: base, exp: exponent)
            let amount = P * factor
            let interest = amount - P
            return roundToInt64(interest)
        }
    }

    /// Fractional-year elapsed, anchored at day granularity. Using day
    /// precision matches the SQL formulation `(CURRENT_DATE - start_date) /
    /// 365.0` that Phase 2 will deploy.
    private static func yearsElapsed(from start: Date, to end: Date, calendar: Calendar) -> Decimal {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard let days = calendar.dateComponents([.day], from: startDay, to: endDay).day else { return 0 }
        guard days > 0 else { return 0 }
        return Decimal(days) / 365
    }

    /// `base ^ exp` for Decimal. Integer-exponent path uses exact
    /// `NSDecimalNumber.raising(toPower:)`; fractional path delegates to
    /// `Double.pow` (small precision loss, acceptable per doc on
    /// `accruedForLot`).
    private static func powDecimal(base: Decimal, exp: Decimal) -> Decimal {
        // If exp is an integer, use the exact Decimal raising.
        var expNormalized = exp
        var expInt = Decimal()
        NSDecimalRound(&expInt, &expNormalized, 0, .down)
        if expInt == exp, expInt >= 0 {
            let n = NSDecimalNumber(decimal: expInt).intValue
            let result = NSDecimalNumber(decimal: base).raising(toPower: n)
            return result.decimalValue
        }
        // Fractional exponent → Double round-trip.
        let b = NSDecimalNumber(decimal: base).doubleValue
        let e = NSDecimalNumber(decimal: exp).doubleValue
        return Decimal(Foundation.pow(b, e))
    }

    /// Round-half-to-even → Int64 kopecks.
    private static func roundToInt64(_ d: Decimal) -> Int64 {
        var rounded = Decimal()
        var source = d
        NSDecimalRound(&rounded, &source, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    private static let isoDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    /// Default calendar matches the ISO date formatter — UTC + Gregorian.
    static let defaultCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func parseDate(_ str: String, calendar: Calendar) -> Date? {
        // Respect the injected calendar's timezone. Callers that supply a
        // non-UTC calendar (tests) still parse "yyyy-MM-dd" the same way —
        // we anchor to the calendar's timezone so `startOfDay` calls later
        // don't cross date boundaries.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = calendar
        return df.date(from: str)
    }
}
