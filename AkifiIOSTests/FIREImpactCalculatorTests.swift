import XCTest
@testable import AkifiIOS

final class FIREImpactCalculatorTests: XCTestCase {

    /// Zero / negative transaction → nil (income / refund row).
    func test_zeroAmount_returnsNil() {
        XCTAssertNil(FIREImpactCalculator.estimate(
            transactionAmount: 0,
            currentNetWorth: 1_000_000_00,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000
        ))
    }

    /// No expenses → no FIRE target → nil.
    func test_zeroExpenses_returnsNil() {
        XCTAssertNil(FIREImpactCalculator.estimate(
            transactionAmount: 100_000,
            currentNetWorth: 1_000_000_00,
            monthlyContribution: 500_000,
            monthlyExpenses: 0
        ))
    }

    /// Tiny purchase rounded to 0 months → nil (no signal worth showing).
    func test_tinyPurchase_returnsNil() {
        XCTAssertNil(FIREImpactCalculator.estimate(
            transactionAmount: 500, // $5
            currentNetWorth: 50_000_00,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000
        ))
    }

    /// Substantial purchase → emits a positive months delay.
    func test_largePurchase_returnsPositiveMonths() {
        // $25,000 car against a $50k NW, $5k/mo savings, $4k/mo expenses.
        let result = FIREImpactCalculator.estimate(
            transactionAmount: 25_000_00,
            currentNetWorth: 50_000_00,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000
        )
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result?.monthsDelay ?? 0, 0)
    }

    /// Bigger spend → larger delay (monotonicity sanity).
    func test_largerPurchase_largerDelay() {
        let small = FIREImpactCalculator.estimate(
            transactionAmount: 5_000_00,
            currentNetWorth: 50_000_00,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000
        )
        let big = FIREImpactCalculator.estimate(
            transactionAmount: 25_000_00,
            currentNetWorth: 50_000_00,
            monthlyContribution: 500_000,
            monthlyExpenses: 400_000
        )
        XCTAssertNotNil(small)
        XCTAssertNotNil(big)
        XCTAssertGreaterThan(big!.monthsDelay, small!.monthsDelay)
    }
}
