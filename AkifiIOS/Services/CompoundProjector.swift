import Foundation

/// Pure compound-interest projection for the standalone calculator
/// screen. Given an initial principal, monthly contribution, annual
/// return and a horizon in years, returns one `Point` per year (plus
/// year 0) so the line chart can render the future-value curve.
///
/// Convention matches `FIREProjector`: monthly contribution is added
/// at the *start* of each month, annual return is divided by 12 to
/// get the monthly rate. Money is `Int64` minor units (kopecks).
///
/// # Why a separate enum?
/// `InterestCalculator` already knows simple/compound formulae for
/// deposits, but its API is "compute interest for one period given
/// frequency". This helper layers on top to produce a *time series*
/// of values for charting. Keeping it separate avoids polluting the
/// deposit math with UI concerns.
enum CompoundProjector {

    struct Point: Sendable, Equatable, Identifiable {
        /// Year offset from start (0 = principal, 1 = end of year 1, …).
        let year: Int
        /// Total balance at the end of that year, base-currency minor units.
        let value: Int64

        var id: Int { year }
    }

    struct Result: Sendable, Equatable {
        let points: [Point]
        /// Final balance — convenience for the summary box (== last
        /// `points.value`).
        let finalValue: Int64
        /// Total user contributions (principal + monthlyContribution × 12 × years).
        let totalContributions: Int64
        /// `finalValue − totalContributions`. Can be negative if
        /// `annualReturn < 0` (left in for completeness, the UI never
        /// shows that).
        let totalInterest: Int64

        static let zero = Result(points: [], finalValue: 0, totalContributions: 0, totalInterest: 0)
    }

    /// Build a point-per-year projection.
    ///
    /// - Parameters:
    ///   - principal: starting amount, kopecks.
    ///   - monthlyContribution: added at start of each month, kopecks.
    ///   - annualReturn: fractional rate (`0.07` = 7%/yr). Negative
    ///     values walk the curve down; UI keeps them non-negative.
    ///   - years: 1...50.
    static func project(
        principal: Int64,
        monthlyContribution: Int64,
        annualReturn: Decimal,
        years: Int
    ) -> Result {
        let n = max(1, min(50, years))
        let monthlyRate = annualReturn / 12

        var balance = Decimal(principal)
        let monthlyContrib = Decimal(monthlyContribution)
        var points: [Point] = [Point(year: 0, value: principal)]

        for year in 1...n {
            for _ in 1...12 {
                // Start-of-month deposit, then accrue.
                balance = (balance + monthlyContrib) * (1 + monthlyRate)
            }
            points.append(Point(year: year, value: clampToInt64(balance)))
        }

        let final = points.last?.value ?? principal
        let contribs = principal + monthlyContribution * 12 * Int64(n)
        return Result(
            points: points,
            finalValue: final,
            totalContributions: contribs,
            totalInterest: final - contribs
        )
    }

    private static func clampToInt64(_ value: Decimal) -> Int64 {
        var d = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &d, 0, .plain)
        let n = NSDecimalNumber(decimal: rounded).doubleValue
        if n >= Double(Int64.max) { return Int64.max }
        if n <= Double(Int64.min) { return Int64.min }
        return Int64(n)
    }
}
