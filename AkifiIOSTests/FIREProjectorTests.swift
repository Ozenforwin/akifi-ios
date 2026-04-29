import XCTest
@testable import AkifiIOS

/// Tests for the FIRE projector — pure math, no fixtures from the DB.
/// Money is always in kopecks (Int64); rates and durations are
/// `Decimal` to keep precision through the inversion.
final class FIREProjectorTests: XCTestCase {

    // MARK: - Helpers

    private let cal = Calendar(identifier: .gregorian)
    private let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: 1))!

    // MARK: - Target math

    /// 4% rule: target = annual expenses × 25.
    /// Monthly burn $4,000 → annual $48,000 → target $1.2M.
    func test_fourPercentRule_targetIs25xAnnualExpenses() {
        let result = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 0,
            monthlyExpenses: 400_000, // $4,000.00 in cents
            now: now
        )
        XCTAssertEqual(result.fireTarget, 4_000_00 * 12 * 25) // $1,200,000.00 = 120_000_000 cents
    }

    /// 3% rule: target ≈ 33.33× annual expenses.
    /// Monthly $4,000 × 12 / 0.03 = $1,600,000 → 160,000,000 cents.
    func test_threePercentRule_higherTarget() {
        let result = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 0,
            monthlyExpenses: 400_000,
            rule: .threePercent,
            now: now
        )
        XCTAssertGreaterThan(result.fireTarget, 159_990_000) // > $1.5999M
        XCTAssertLessThan(result.fireTarget,    160_010_000) // < $1.6001M
    }

    // MARK: - Edge cases

    func test_zeroExpenses_returnsUnknown() {
        let result = FIREProjector.project(
            currentNetWorth: 100_000_00,
            monthlyContribution: 50_000,
            monthlyExpenses: 0,
            now: now
        )
        XCTAssertEqual(result.fireTarget, 0)
        XCTAssertNil(result.yearsToFIRE)
        XCTAssertNil(result.fireDate)
        XCTAssertTrue(result.scenarios.isEmpty)
    }

    /// Already at or above target → years to FIRE = 0, date = now.
    /// Target for $4k/mo is $1.2M = 120,000,000 cents; $2M = 200,000,000 is above.
    func test_alreadyFIRE_zeroYears() {
        let result = FIREProjector.project(
            currentNetWorth: 200_000_000, // $2,000,000 in cents
            monthlyContribution: 0,
            monthlyExpenses: 400_000,
            now: now
        )
        XCTAssertEqual(result.yearsToFIRE, 0)
        XCTAssertEqual(result.fireDate, now)
    }

    /// Zero contribution + below target + zero return → unreachable.
    func test_zeroEverything_returnsNil() {
        let result = FIREProjector.project(
            currentNetWorth: 100_000_00,
            monthlyContribution: 0,
            monthlyExpenses: 400_000,
            expectedAnnualReturn: 0,
            now: now
        )
        XCTAssertNil(result.yearsToFIRE)
    }

    /// Zero return + positive contribution → linear growth, computable.
    /// $0 NW, $5,000/mo to FIRE target $1.2M → 240 mo / 12 = 20 yrs.
    func test_zeroReturn_linearGrowth() {
        let result = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 500_000, // $5,000.00 cents
            monthlyExpenses: 400_000,
            expectedAnnualReturn: 0,
            now: now
        )
        XCTAssertEqual(result.yearsToFIRE, 20)
    }

    // MARK: - Compounding sanity

    /// $0 NW, $5,000/mo at 7% annual → reaches $1.2M sometime around
    /// 13-14 years. Loose-bound assertion to keep the test resilient
    /// to rounding tweaks in the inverter.
    func test_canonicalScenario_reachesFIREinReasonableTime() {
        let result = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000,
            now: now
        )
        guard let years = result.yearsToFIRE else {
            return XCTFail("Should reach FIRE")
        }
        let yearsAsDouble = NSDecimalNumber(decimal: years).doubleValue
        XCTAssertGreaterThan(yearsAsDouble, 12)
        XCTAssertLessThan(yearsAsDouble, 15)
    }

    /// Higher contribution monotonically reduces years to FIRE.
    func test_higherContribution_alwaysFasterFIRE() {
        let lower = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 200_000,
            monthlyExpenses: 400_000,
            now: now
        )
        let higher = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 800_000,
            monthlyExpenses: 400_000,
            now: now
        )
        // Both should reach FIRE; higher is faster.
        XCTAssertNotNil(lower.yearsToFIRE)
        XCTAssertNotNil(higher.yearsToFIRE)
        XCTAssertGreaterThan(lower.yearsToFIRE!, higher.yearsToFIRE!)
    }

    // MARK: - Scenarios sweep

    /// `scenarios` should always have 5 entries: 0, 25, 50, 75, 100%.
    func test_scenarios_fiveSteps() {
        let result = FIREProjector.project(
            currentNetWorth: 0,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000,
            now: now,
            disposableMonthly: 1_000_000
        )
        XCTAssertEqual(result.scenarios.map { $0.percent }, [0, 25, 50, 75, 100])
        // Higher percentage → fewer years (where reachable).
        let nonNil = result.scenarios.compactMap { $0.years }
        XCTAssertEqual(nonNil, nonNil.sorted(by: >))
    }

    // MARK: - Investable vs include-all

    /// "Include illiquid" toggle is a caller-side decision —
    /// FIREProjector consumes the net worth as a number. With
    /// monthly contributions, a higher starting NW reaches FIRE sooner.
    /// Target = $1.2M ($1,200,000 = 120,000,000 cents). Below it,
    /// monthly contributions of $5k at 7%/yr eventually get there.
    func test_includingIlliquid_movesYearsLowerWhenHigherNW() {
        let liquidOnly = FIREProjector.project(
            currentNetWorth: 50_000_000,   // $500,000 (under target)
            monthlyContribution: 500_000,  // $5k/mo
            monthlyExpenses: 400_000,
            now: now
        )
        let withIlliquid = FIREProjector.project(
            currentNetWorth: 80_000_000,   // $800,000 (under target, higher)
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000,
            now: now
        )
        XCTAssertNotNil(liquidOnly.yearsToFIRE)
        XCTAssertNotNil(withIlliquid.yearsToFIRE)
        XCTAssertGreaterThan(liquidOnly.yearsToFIRE!, withIlliquid.yearsToFIRE!)
    }
}
