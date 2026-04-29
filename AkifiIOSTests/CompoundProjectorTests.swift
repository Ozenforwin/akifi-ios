import XCTest
@testable import AkifiIOS

final class CompoundProjectorTests: XCTestCase {

    /// Year 0 always equals the starting principal exactly — keeps
    /// the chart anchored at the user's input.
    func test_yearZero_equalsPrincipal() {
        let r = CompoundProjector.project(
            principal: 100_000_00,
            monthlyContribution: 10_000_00,
            annualReturn: Decimal(string: "0.07")!,
            years: 5
        )
        XCTAssertEqual(r.points.first?.value, 100_000_00)
    }

    /// Returns one Point per year + year 0 → years + 1 entries total.
    func test_pointsCount_equalsYearsPlusOne() {
        let r = CompoundProjector.project(
            principal: 0, monthlyContribution: 0,
            annualReturn: 0, years: 10
        )
        XCTAssertEqual(r.points.count, 11)
    }

    /// Zero contribution, zero return → balance stays at the
    /// principal forever.
    func test_zeroEverything_balanceConstant() {
        let r = CompoundProjector.project(
            principal: 50_000,
            monthlyContribution: 0,
            annualReturn: 0,
            years: 3
        )
        XCTAssertTrue(r.points.allSatisfy { $0.value == 50_000 })
        XCTAssertEqual(r.totalContributions, 50_000)
        XCTAssertEqual(r.totalInterest, 0)
    }

    /// Zero return, monthly contribution accumulates linearly:
    /// principal + contrib × 12 × years.
    func test_zeroReturn_linearAccumulation() {
        let r = CompoundProjector.project(
            principal: 0,
            monthlyContribution: 1_000,
            annualReturn: 0,
            years: 2
        )
        // 1000 × 12 × 2 = 24,000
        XCTAssertEqual(r.finalValue, 24_000)
        XCTAssertEqual(r.totalContributions, 24_000)
    }

    /// Canonical sanity: $100k principal, $10k/mo, 7%/yr, 20 yrs
    /// should land roughly between $5.5M and $7M (FIRE textbook
    /// example; loose bounds keep the test resilient to rounding).
    /// Cents: $5.5M = 550,000,000; $7M = 700,000,000.
    func test_canonicalScenario_inExpectedRange() {
        let r = CompoundProjector.project(
            principal: 100_000_00,   // $100,000.00
            monthlyContribution: 10_000_00, // $10,000.00
            annualReturn: Decimal(string: "0.07")!,
            years: 20
        )
        XCTAssertGreaterThan(r.finalValue, 550_000_000) // > $5.5M
        XCTAssertLessThan(r.finalValue,    700_000_000) // < $7.0M
    }

    /// Total contributions are exactly principal + monthly × 12 × years
    /// (independent of compounding, by construction).
    func test_totalContributions_principalPlusMonthlySum() {
        let r = CompoundProjector.project(
            principal: 1_000,
            monthlyContribution: 100,
            annualReturn: Decimal(string: "0.05")!,
            years: 10
        )
        XCTAssertEqual(r.totalContributions, 1_000 + 100 * 12 * 10)
    }

    /// Years are clamped to 1...50 — input of 0 → 1 year, 100 → 50 yrs.
    func test_yearsClamping() {
        let zero = CompoundProjector.project(
            principal: 100, monthlyContribution: 0,
            annualReturn: 0, years: 0
        )
        XCTAssertEqual(zero.points.count, 2) // year 0 + year 1
        let huge = CompoundProjector.project(
            principal: 100, monthlyContribution: 0,
            annualReturn: 0, years: 100
        )
        XCTAssertEqual(huge.points.count, 51) // year 0 + 50 yrs
    }
}
