import XCTest
@testable import AkifiIOS

/// Tests for the pure net-worth engine. See `NetWorthCalculator` for the
/// contract. All monetary inputs are Int64 kopecks; FX rates are USD-pivot
/// Decimal values.
final class NetWorthCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeAsset(category: AssetCategory, value: Int64, currency: String = "RUB") -> Asset {
        Asset(
            id: UUID().uuidString,
            userId: "user-1",
            name: "test-\(category.rawValue)",
            category: category,
            currentValue: value,
            currency: currency
        )
    }

    private func makeLiability(category: LiabilityCategory, balance: Int64, currency: String = "RUB") -> Liability {
        Liability(
            id: UUID().uuidString,
            userId: "user-1",
            name: "test-\(category.rawValue)",
            category: category,
            currentBalance: balance,
            currency: currency
        )
    }

    // MARK: - Empty case

    /// No accounts, no assets, no liabilities → everything zero.
    func test_zeroNetWorth_emptyCase() {
        let result = NetWorthCalculator.compute(
            accountBalances: [],
            assets: [],
            liabilities: [],
            fxRates: [:],
            baseCurrency: .rub
        )

        XCTAssertEqual(result.accountsTotal, 0)
        XCTAssertEqual(result.assetsTotal, 0)
        XCTAssertEqual(result.liabilitiesTotal, 0)
        XCTAssertEqual(result.netWorth, 0)
        XCTAssertTrue(result.byAssetCategory.isEmpty)
        XCTAssertTrue(result.byLiabilityCategory.isEmpty)
    }

    // MARK: - Simple positive case

    /// 100k kopecks accounts + 500k kopecks real-estate asset − 200k
    /// kopecks mortgage → 400k kopecks net worth. All RUB, no FX.
    func test_simpleCase_positiveNetWorth() {
        let accounts: [(String, Int64)] = [(accountCurrency: "RUB", amount: 100_000)]
        let assets = [makeAsset(category: .realEstate, value: 500_000)]
        let liabilities = [makeLiability(category: .mortgage, balance: 200_000)]

        let result = NetWorthCalculator.compute(
            accountBalances: accounts,
            assets: assets,
            liabilities: liabilities,
            fxRates: ["USD": 1.0, "RUB": 90.0],
            baseCurrency: .rub
        )

        XCTAssertEqual(result.accountsTotal, 100_000)
        XCTAssertEqual(result.assetsTotal, 500_000)
        XCTAssertEqual(result.liabilitiesTotal, 200_000)
        XCTAssertEqual(result.netWorth, 400_000)

        XCTAssertEqual(result.byAssetCategory[.realEstate], 500_000)
        XCTAssertEqual(result.byLiabilityCategory[.mortgage], 200_000)
    }

    // MARK: - Negative net worth

    /// Debt-heavy: 50k accounts + 100k assets − 500k liabilities → net
    /// worth −350k kopecks. Negative values are valid and must flow
    /// through the arithmetic unchanged.
    func test_negativeNetWorth_debtExceedsTotal() {
        let accounts: [(String, Int64)] = [(accountCurrency: "RUB", amount: 50_000)]
        let assets = [makeAsset(category: .vehicle, value: 100_000)]
        let liabilities = [
            makeLiability(category: .mortgage, balance: 400_000),
            makeLiability(category: .creditCard, balance: 100_000)
        ]

        let result = NetWorthCalculator.compute(
            accountBalances: accounts,
            assets: assets,
            liabilities: liabilities,
            fxRates: [:],
            baseCurrency: .rub
        )

        XCTAssertEqual(result.accountsTotal, 50_000)
        XCTAssertEqual(result.assetsTotal, 100_000)
        XCTAssertEqual(result.liabilitiesTotal, 500_000)
        XCTAssertEqual(result.netWorth, -350_000)
        XCTAssertLessThan(result.netWorth, 0)
    }

    // MARK: - Multi-currency FX normalization

    /// ByBit USD account 100 USD (10_000 kopecks) at rate RUB=75 should
    /// convert to 7_500 RUB (750_000 kopecks). Tinkoff 500 RUB (50_000
    /// kopecks) passes through unchanged. Total → 800_000 kopecks RUB.
    ///
    /// Input: 10_000 USD-kopecks + 50_000 RUB-kopecks
    /// Expected: (10_000 / 1.0 * 75) + 50_000 = 750_000 + 50_000 = 800_000
    func test_multiCurrency_fxNormalization() {
        let accounts: [(String, Int64)] = [
            (accountCurrency: "USD", amount: 10_000),
            (accountCurrency: "RUB", amount: 50_000)
        ]

        let rates: [String: Decimal] = ["USD": Decimal(1.0), "RUB": Decimal(75.0)]
        let result = NetWorthCalculator.compute(
            accountBalances: accounts,
            assets: [],
            liabilities: [],
            fxRates: rates,
            baseCurrency: .rub
        )

        XCTAssertEqual(result.accountsTotal, 800_000)
        XCTAssertEqual(result.netWorth, 800_000)
    }

    // MARK: - Missing FX rate fallback

    /// If the user's FX map is missing `RUB` (cold start, offline),
    /// the calculator must NOT crash and must NOT silently return zero.
    /// It falls back to face-value — yields a small drift but keeps the
    /// app usable. 100 USD account + no rates → 100 USD face-value kopecks
    /// credited to the RUB total.
    func test_multiCurrency_missingFxRate_fallback1to1() {
        let accounts: [(String, Int64)] = [
            (accountCurrency: "USD", amount: 10_000)
        ]

        // Missing both "USD" and "RUB" — pure fallback path.
        let result = NetWorthCalculator.compute(
            accountBalances: accounts,
            assets: [],
            liabilities: [],
            fxRates: [:],
            baseCurrency: .rub
        )

        XCTAssertEqual(result.accountsTotal, 10_000, "fallback must preserve face-value amount")
        XCTAssertEqual(result.netWorth, 10_000)

        // Also exercise: rates present but zero.
        let zeroRates: [String: Decimal] = ["USD": 0, "RUB": 75]
        let resultZero = NetWorthCalculator.compute(
            accountBalances: accounts,
            assets: [],
            liabilities: [],
            fxRates: zeroRates,
            baseCurrency: .rub
        )
        XCTAssertEqual(resultZero.accountsTotal, 10_000,
                       "zero rate divisor must trigger the fallback, not divide-by-zero")
    }
}
