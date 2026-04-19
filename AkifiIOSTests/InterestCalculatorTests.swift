import XCTest
@testable import AkifiIOS

/// Tests for the pure interest-accrual engine.
/// All amounts are Int64 kopecks; rate is an annual percentage.
///
/// We use a deterministic UTC Gregorian calendar to match the calculator's
/// `defaultCalendar`, so reproduction on any CI locale is identical.
final class InterestCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: iso)!
    }

    private func contribution(amount: Int64, at iso: String) -> DepositContribution {
        DepositContribution(
            id: UUID().uuidString,
            depositId: "dep-1",
            userId: "user-1",
            amount: amount,
            contributedAt: iso
        )
    }

    // MARK: - Simple interest

    /// 100 000 kopecks principal at 12% simple interest for 365 days =
    /// exactly 12 000 kopecks interest. I = P * r * t, t = 1 year.
    func test_simple_interest_1year() {
        let lots = [contribution(amount: 100_000, at: "2026-01-01")]
        let accrued = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 12,
            frequency: .simple,
            asOf: date("2027-01-01"),
            calendar: utcCal
        )
        // 100_000 * 0.12 * 1 year = 12_000
        XCTAssertEqual(accrued, 12_000)
    }

    // MARK: - Monthly compound

    /// 100 000 at 12% monthly compound for 365 days. (1 + 0.12/12)^12 - 1
    /// ≈ 0.12682503… → ~12 683 kopecks (rounded to nearest integer).
    /// Accept a small tolerance window to cover rounding mode edge cases.
    func test_monthly_compound_1year() {
        let lots = [contribution(amount: 100_000, at: "2026-01-01")]
        let accrued = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 12,
            frequency: .monthly,
            asOf: date("2027-01-01"),
            calendar: utcCal
        )
        // Expected: ~12_683 kopecks. Tolerance ±3 to absorb Double fallback.
        XCTAssertGreaterThanOrEqual(accrued, 12_680)
        XCTAssertLessThanOrEqual(accrued, 12_686)
    }

    // MARK: - Daily compound

    /// 100 000 at 12% daily compound for 365 days. (1 + 0.12/365)^365 - 1
    /// ≈ 0.12747… → ~12 747 kopecks.
    func test_daily_compound_1year() {
        let lots = [contribution(amount: 100_000, at: "2026-01-01")]
        let accrued = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 12,
            frequency: .daily,
            asOf: date("2027-01-01"),
            calendar: utcCal
        )
        // Expected: ~12_747. Tolerance ±3.
        XCTAssertGreaterThanOrEqual(accrued, 12_744)
        XCTAssertLessThanOrEqual(accrued, 12_750)
    }

    // MARK: - Yearly compound over 5 years

    /// 100 000 at 10% yearly compound for 5 years. (1.1)^5 - 1 = 0.61051 →
    /// 61 051 kopecks — but only if t is *exactly* 5. We compute t as
    /// `days/365`, and 5 calendar years between 2026-01-01 and 2031-01-01
    /// span 1826 days (one leap year), giving t ≈ 5.00274. So the
    /// real expected accrued is ~(1.1)^5.00274 - 1 ≈ 0.61093 → ~61 093.
    /// Tolerance ±10 accommodates day-count / precision drift.
    func test_yearly_compound_5years() {
        let lots = [contribution(amount: 100_000, at: "2026-01-01")]
        let accrued = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 10,
            frequency: .yearly,
            asOf: date("2031-01-01"),
            calendar: utcCal
        )
        XCTAssertGreaterThanOrEqual(accrued, 61_080)
        XCTAssertLessThanOrEqual(accrued, 61_110)
    }

    // MARK: - Lot-based accrual

    /// Two contributions with different start dates. Total accrued should
    /// equal per-lot accrual summed — NOT the naive aggregate (which
    /// would credit the second lot with interest before it existed).
    ///
    /// Lot 1: 100 000 on day 0 (2026-01-01), compounded to 2026-12-31 =
    ///        ~12 000 (simple).
    /// Lot 2: 50 000 on day 30 (2026-01-31), compounded to 2026-12-31 =
    ///        only for the remaining ~334 days, not 365.
    ///
    /// Expected: accrual_lot1 + accrual_lot2, both strictly positive,
    /// sum < naive_aggregate_principal * rate (would over-credit lot 2).
    func test_lot_based_twoContributions_differentStartDates() {
        let lots = [
            contribution(amount: 100_000, at: "2026-01-01"),
            contribution(amount: 50_000, at: "2026-01-31")
        ]
        let asOf = date("2026-12-31")

        let lotBased = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 12,
            frequency: .simple,
            asOf: asOf,
            calendar: utcCal
        )

        // Expected per-lot math (simple interest):
        //   Lot 1: 364 days → 100_000 * 0.12 * 364/365 ≈ 11_967
        //   Lot 2: 334 days → 50_000 * 0.12 * 334/365 ≈ 5_490
        //   Sum ≈ 17_457
        //
        // Naive aggregate (the WRONG way) would pretend both lots started
        // on day 0: 150_000 * 0.12 * 364/365 ≈ 17_950. Our lot-based
        // implementation must stay strictly under that to prove correctness.
        let naiveAggregate: Int64 = {
            let units = (Decimal(150_000) * Decimal(string: "0.12")!) * (Decimal(364) / 365)
            var rounded = Decimal()
            var src = units
            NSDecimalRound(&rounded, &src, 0, .plain)
            return Int64(truncating: rounded as NSDecimalNumber)
        }()

        XCTAssertLessThan(lotBased, naiveAggregate, "lot-based must be < naive aggregate")
        XCTAssertGreaterThan(lotBased, 0)
        // Ballpark sanity: between the sum of two simple-interest lots.
        XCTAssertGreaterThanOrEqual(lotBased, 17_400)
        XCTAssertLessThanOrEqual(lotBased, 17_500)
    }

    // MARK: - Zero rate

    /// A 0% rate must produce zero interest regardless of time or
    /// compounding frequency. Short-circuit path.
    func test_zeroRate_zeroAccrued() {
        let lots = [contribution(amount: 1_000_000, at: "2026-01-01")]
        for freq in CompoundFrequency.allCases {
            let accrued = InterestCalculator.accrueInterest(
                contributions: lots,
                rate: 0,
                frequency: freq,
                asOf: date("2030-01-01"),
                calendar: utcCal
            )
            XCTAssertEqual(accrued, 0, "frequency \(freq) must yield 0 at 0% rate")
        }
    }

    // MARK: - Projection at maturity

    /// `projectedMaturityValue(asOf: endDate)` must equal principal +
    /// `accrueInterest(asOf: endDate)`. Identity check ensures the two
    /// helpers agree on the same timeline.
    func test_projectedMaturityValue_equalsAccrued_atMaturityDate() {
        let lots = [contribution(amount: 200_000, at: "2026-01-01")]
        let maturity = date("2027-01-01")
        let accrued = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 10,
            frequency: .monthly,
            asOf: maturity,
            calendar: utcCal
        )
        let projected = InterestCalculator.projectedMaturityValue(
            contributions: lots,
            rate: 10,
            frequency: .monthly,
            maturityDate: maturity,
            calendar: utcCal
        )
        XCTAssertEqual(projected, 200_000 + accrued)
    }

    // MARK: - Negative duration

    /// If `asOf` is before every contribution's start date, no interest
    /// should accrue (not negative, not rollover).
    func test_futureContribution_zeroAccrued() {
        let lots = [contribution(amount: 100_000, at: "2027-01-01")]
        let accrued = InterestCalculator.accrueInterest(
            contributions: lots,
            rate: 12,
            frequency: .monthly,
            asOf: date("2026-06-01"),
            calendar: utcCal
        )
        XCTAssertEqual(accrued, 0)
    }

    // MARK: - Total principal

    func test_totalPrincipal_sumsAllContributions() {
        let lots = [
            contribution(amount: 100_000, at: "2026-01-01"),
            contribution(amount: 50_000, at: "2026-02-01"),
            contribution(amount: 25_000, at: "2026-03-01")
        ]
        XCTAssertEqual(InterestCalculator.totalPrincipal(lots), 175_000)
    }
}
