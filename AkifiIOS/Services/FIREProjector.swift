import Foundation

/// Pure FIRE-projection math.
///
/// Given a current investable net worth, the user's average monthly
/// expenses (their "burn rate"), and how much of their disposable
/// income they're committing to investing each month, computes:
///
/// * `fireTarget` — the corpus large enough to safely cover those
///   expenses forever according to the chosen withdrawal rule (4%
///   default → target = annual expenses × 25).
/// * `yearsToFIRE` — how many years of compounding at
///   `expectedAnnualReturn` (default 7% nominal, the long-run
///   inflation-adjusted S&P proxy used by most FIRE calculators) it
///   takes to grow from `currentNetWorth` to `fireTarget` while
///   contributing `monthlyContribution` at the start of each month.
/// * `fireDate` — `now + yearsToFIRE`.
/// * `scenarios` — what `yearsToFIRE` would be if the user invested
///   {0%, 25%, 50%, 75%, 100%} of their current disposable income
///   instead of the slider value, so the UI can show "every 10
///   percentage points buys you N years."
///
/// All money is in `Int64` minor units (kopecks). Returns are
/// `Decimal` to preserve precision through `pow`.
///
/// # Edge cases
///
/// * `monthlyExpenses ≤ 0` → no FIRE target makes sense, returns
///   `.unknown` (UI shows insufficient-data state).
/// * `currentNetWorth ≥ fireTarget` → already FIRE; `yearsToFIRE = 0`
///   and `fireDate = now`.
/// * `monthlyContribution ≤ 0 && currentNetWorth < fireTarget` →
///   without contributions, only growth at `expectedAnnualReturn`
///   matters. Solved analytically with `log(target/current)/log(1+r)`.
/// * `expectedAnnualReturn ≤ 0` → linear growth, no compounding.
enum FIREProjector {

    // MARK: - Models

    /// Withdrawal-rate rules. 4% is the canonical Trinity-study
    /// threshold ("safe withdrawal rate"); 3% is the more
    /// conservative ERN-style version often used outside US markets.
    enum WithdrawalRule: Sendable {
        case fourPercent      // target = annual expenses × 25
        case threePercent     // target = annual expenses × 33.33…
        case custom(Decimal)  // target = annual expenses × (1 / rate)

        /// Target-multiplier (`1 / withdrawal rate`).
        var multiplier: Decimal {
            switch self {
            case .fourPercent:        return 25
            case .threePercent:       return Decimal(string: "33.3333333333")!
            case .custom(let rate) where rate > 0: return 1 / rate
            case .custom:             return 25  // safety default
            }
        }
    }

    struct Projection: Sendable, Equatable {
        /// Corpus needed for FIRE in base-currency minor units.
        let fireTarget: Int64
        /// Years from `now` until `currentNetWorth + contributions`
        /// reaches `fireTarget`. `nil` means "unreachable in 200 yrs".
        let yearsToFIRE: Decimal?
        let fireDate: Date?
        /// Slider scenarios. Keys are percentages (0...100); values
        /// are years to FIRE under that contribution percentage.
        /// `nil` means unreachable.
        let scenarios: [(percent: Int, years: Decimal?)]

        static let unknown = Projection(
            fireTarget: 0,
            yearsToFIRE: nil,
            fireDate: nil,
            scenarios: []
        )

        /// SwiftUI `Equatable` synthesis can't see through the
        /// `[(percent, years)]` tuple array — we compare manually.
        static func == (lhs: Projection, rhs: Projection) -> Bool {
            lhs.fireTarget == rhs.fireTarget
                && lhs.yearsToFIRE == rhs.yearsToFIRE
                && lhs.fireDate == rhs.fireDate
                && lhs.scenarios.count == rhs.scenarios.count
                && zip(lhs.scenarios, rhs.scenarios).allSatisfy {
                    $0.percent == $1.percent && $0.years == $1.years
                }
        }
    }

    // MARK: - Public API

    /// Compute a FIRE projection.
    ///
    /// - Parameters:
    ///   - currentNetWorth: investable net worth in base-currency
    ///     minor units (excludes illiquid by default — caller decides).
    ///   - monthlyContribution: how much the user adds each month.
    ///   - monthlyExpenses: average monthly burn (excludes
    ///     subscriptions only if the caller already excluded them).
    ///   - expectedAnnualReturn: real (or nominal — caller's choice)
    ///     return as a fraction (`0.07` = 7%/yr). Defaults to 0.07.
    ///   - rule: withdrawal rule. Default 4%.
    ///   - now: injectable clock.
    ///   - disposableMonthly: optional; if non-nil, fills `scenarios`
    ///     by varying `monthlyContribution` from 0 to `disposable`
    ///     in 25-pt steps. If nil, uses `monthlyContribution` itself
    ///     as the 100% baseline.
    ///   - calendar: injectable.
    static func project(
        currentNetWorth: Int64,
        monthlyContribution: Int64,
        monthlyExpenses: Int64,
        expectedAnnualReturn: Decimal = Decimal(string: "0.07")!,
        rule: WithdrawalRule = .fourPercent,
        now: Date = Date(),
        disposableMonthly: Int64? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Projection {
        guard monthlyExpenses > 0 else { return .unknown }

        let annualExpenses = Decimal(monthlyExpenses) * 12
        let targetDecimal = annualExpenses * rule.multiplier
        let fireTarget = clampToInt64(targetDecimal)

        let years = yearsTo(
            target: targetDecimal,
            current: Decimal(currentNetWorth),
            monthlyContribution: Decimal(monthlyContribution),
            annualReturn: expectedAnnualReturn
        )

        let fireDate: Date? = years.flatMap { y in
            // Whole months → add precisely; partial month rounds up
            // (so the user sees the date *they reach* FIRE, not before).
            let months = NSDecimalNumber(decimal: y * 12).doubleValue
            let wholeMonths = Int(ceil(months))
            return calendar.date(byAdding: .month, value: wholeMonths, to: now)
        }

        // Scenario sweep — vary monthly contribution 0…disposable in
        // 25-percent steps. If caller didn't tell us their disposable,
        // we sweep relative to the *current* monthlyContribution (i.e.
        // 100% scenario equals what they're already doing).
        let baseline = max(disposableMonthly ?? monthlyContribution, 0)
        var scenarios: [(percent: Int, years: Decimal?)] = []
        for pct in stride(from: 0, through: 100, by: 25) {
            let contribution = Decimal(baseline) * Decimal(pct) / 100
            let y = yearsTo(
                target: targetDecimal,
                current: Decimal(currentNetWorth),
                monthlyContribution: contribution,
                annualReturn: expectedAnnualReturn
            )
            scenarios.append((percent: pct, years: y))
        }

        return Projection(
            fireTarget: fireTarget,
            yearsToFIRE: years,
            fireDate: fireDate,
            scenarios: scenarios
        )
    }

    // MARK: - Private

    /// Solves for the number of years it takes for `current` to grow
    /// to `target` while contributing `monthlyContribution` at the
    /// *start* of each month and earning `annualReturn` p.a.
    ///
    /// Uses the closed-form FV formula with monthly compounding:
    ///   FV = current·(1+i)^n + contribution · ((1+i)^n − 1)/i · (1+i)
    /// where i = annualReturn/12, n = number of months. We invert
    /// numerically rather than analytically because the result depends
    /// on whether `i = 0` and we want to handle a zero-return case.
    ///
    /// Returns `nil` when the target is unreachable in 200 years.
    private static func yearsTo(
        target: Decimal,
        current: Decimal,
        monthlyContribution: Decimal,
        annualReturn: Decimal
    ) -> Decimal? {
        if current >= target { return 0 }

        let monthly = annualReturn / 12

        // Linear growth shortcut when there's no return at all.
        if annualReturn <= 0 {
            guard monthlyContribution > 0 else { return nil }
            let months = (target - current) / monthlyContribution
            return months / 12
        }

        // Walk forward month by month, capping at 200y so we don't
        // hang on degenerate inputs.
        var balance = current
        let maxMonths = 200 * 12
        for n in 1...maxMonths {
            // Start-of-month contribution → grows for the full month.
            balance = (balance + monthlyContribution) * (1 + monthly)
            if balance >= target {
                return Decimal(n) / 12
            }
        }
        return nil
    }

    /// Saturating Decimal → Int64 conversion. The FIRE target for an
    /// extreme-spend user could exceed Int64; cap rather than overflow.
    private static func clampToInt64(_ value: Decimal) -> Int64 {
        var d = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &d, 0, .plain)
        let n = NSDecimalNumber(decimal: rounded).doubleValue
        if n >= Double(Int64.max) { return Int64.max }
        if n <= 0 { return 0 }
        return Int64(n)
    }
}
