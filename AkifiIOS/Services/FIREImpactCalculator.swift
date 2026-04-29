import Foundation

/// Pure helper that estimates how much a single expense pushes the
/// FIRE date back. Used by `TransactionDetailView` to surface a
/// "FIRE impact" line on large purchases ("This delays your FIRE
/// date by ~3 months").
///
/// The math is intentionally simple:
/// 1. Compute baseline `yearsToFIRE` with the user's current
///    investable net worth.
/// 2. Compute alternate `yearsToFIRE` with that net worth +
///    transactionAmount (the world where the user kept the money
///    invested instead of spending it).
/// 3. Difference, in months, rounded to whole months.
///
/// We deliberately ignore the loss-of-future-compounding-on-this-
/// purchase angle because surfacing it here would be a slippery slope
/// (a $5 coffee → "delays FIRE by 5 days" is anti-product). The
/// caller decides whether the transaction is "large enough" to show
/// the line at all (`isLargeExpense`).
enum FIREImpactCalculator {

    struct Estimate: Sendable, Equatable {
        /// Months by which spending the transaction shifts the FIRE
        /// date later vs keeping the money invested. Always > 0.
        let monthsDelay: Int
        /// Baseline (current) years to FIRE.
        let baselineYears: Decimal
        /// Years to FIRE if the money stayed invested.
        let alternateYears: Decimal
    }

    /// Returns nil when:
    /// * `transactionAmount ≤ 0` (income / refund / refund-like row),
    /// * baseline or alternate projection is unreachable,
    /// * the difference rounds to 0 months (no signal worth showing).
    ///
    /// - Parameters:
    ///   - transactionAmount: minor units in base currency. Caller is
    ///     responsible for FX-normalising before passing.
    ///   - currentNetWorth: minor units in base currency.
    ///   - monthlyContribution: same units the FIREProjector takes.
    ///   - monthlyExpenses: same units the FIREProjector takes.
    static func estimate(
        transactionAmount: Int64,
        currentNetWorth: Int64,
        monthlyContribution: Int64,
        monthlyExpenses: Int64
    ) -> Estimate? {
        guard transactionAmount > 0, monthlyExpenses > 0 else { return nil }

        let baseline = FIREProjector.project(
            currentNetWorth: currentNetWorth,
            monthlyContribution: monthlyContribution,
            monthlyExpenses: monthlyExpenses
        )
        let alternate = FIREProjector.project(
            currentNetWorth: currentNetWorth + transactionAmount,
            monthlyContribution: monthlyContribution,
            monthlyExpenses: monthlyExpenses
        )

        guard let baseYears = baseline.yearsToFIRE,
              let altYears = alternate.yearsToFIRE,
              baseYears > altYears else {
            return nil
        }

        // Whole-month rounding — any sub-month diff is noise.
        let diffMonths = NSDecimalNumber(decimal: (baseYears - altYears) * 12).doubleValue
        let rounded = Int(diffMonths.rounded())
        guard rounded > 0 else { return nil }

        return Estimate(
            monthsDelay: rounded,
            baselineYears: baseYears,
            alternateYears: altYears
        )
    }
}
