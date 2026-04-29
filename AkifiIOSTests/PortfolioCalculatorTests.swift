import XCTest
@testable import AkifiIOS

/// Tests for the portfolio aggregation engine. Mirrors the style of
/// `NetWorthCalculatorTests`. All inputs use Decimal for prices/qty
/// and Int64 kopecks for cost basis / sums; FX is USD-pivot.
final class PortfolioCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeAsset(
        id: String = UUID().uuidString,
        category: AssetCategory = .investment,
        currency: String = "USD",
        currentValue: Int64 = 0
    ) -> Asset {
        Asset(
            id: id,
            userId: "user-1",
            name: "asset-\(currency)",
            category: category,
            currentValue: currentValue,
            currency: currency
        )
    }

    private func makeHolding(
        assetId: String,
        ticker: String = "VOO",
        kind: HoldingKind = .etf,
        quantity: Decimal,
        costBasis: Int64,
        lastPrice: Decimal
    ) -> InvestmentHolding {
        InvestmentHolding(
            id: UUID().uuidString,
            userId: "user-1",
            assetId: assetId,
            ticker: ticker,
            kind: kind,
            quantity: quantity,
            costBasis: costBasis,
            lastPrice: lastPrice,
            lastPriceDate: "2026-04-29"
        )
    }

    // MARK: - Empty case

    /// No holdings → all zeros, ROI nil (avoid div-by-zero).
    func test_emptyHoldings_returnsZeroSummary() {
        let result = PortfolioCalculator.aggregate(
            holdings: [],
            assetsById: [:],
            fxRates: [:],
            baseCurrency: .usd
        )

        XCTAssertEqual(result.totalValue, 0)
        XCTAssertEqual(result.totalCostBasis, 0)
        XCTAssertEqual(result.unrealizedPnL, 0)
        XCTAssertNil(result.roi)
        XCTAssertTrue(result.byKind.isEmpty)
        XCTAssertTrue(result.byCurrency.isEmpty)
    }

    // MARK: - Single-currency portfolio

    /// VOO: 10 units × $500 = $5000 current; cost basis $4000 → +25% ROI.
    /// All in USD, no FX conversion. Using cents (Int64), so $5000 = 500_000.
    func test_singleHolding_simpleROI() {
        let asset = makeAsset(currency: "USD")
        let holding = makeHolding(
            assetId: asset.id,
            ticker: "VOO",
            kind: .etf,
            quantity: 10,
            costBasis: 400_000, // $4,000.00 in cents
            lastPrice: 500
        )

        let result = PortfolioCalculator.aggregate(
            holdings: [holding],
            assetsById: [asset.id: asset],
            fxRates: ["USD": 1.0],
            baseCurrency: .usd
        )

        XCTAssertEqual(result.totalValue, 500_000)        // $5,000.00
        XCTAssertEqual(result.totalCostBasis, 400_000)    // $4,000.00
        XCTAssertEqual(result.unrealizedPnL, 100_000)
        XCTAssertEqual(result.roi, Decimal(string: "0.25"))  // +25%
        XCTAssertEqual(result.byKind[.etf], 500_000)
        XCTAssertEqual(result.byCurrency["USD"], 500_000)
    }

    /// Two holdings of different `kind` → both counted in totals,
    /// each appears under its own key in `byKind`.
    func test_twoKinds_bothCountedInBreakdown() {
        let asset = makeAsset(currency: "USD")
        // VOO 10 × $500 = $5000 → 500_000 cents; cost $4000 → 400_000 cents.
        let voo = makeHolding(
            assetId: asset.id, ticker: "VOO", kind: .etf,
            quantity: 10, costBasis: 400_000, lastPrice: 500
        )
        // AAPL 5 × $250 = $1250 → 125_000 cents; cost $1000 → 100_000 cents.
        let aapl = makeHolding(
            assetId: asset.id, ticker: "AAPL", kind: .stock,
            quantity: 5, costBasis: 100_000, lastPrice: 250
        )

        let result = PortfolioCalculator.aggregate(
            holdings: [voo, aapl],
            assetsById: [asset.id: asset],
            fxRates: ["USD": 1.0],
            baseCurrency: .usd
        )

        XCTAssertEqual(result.totalValue, 500_000 + 125_000)
        XCTAssertEqual(result.byKind[.etf], 500_000)
        XCTAssertEqual(result.byKind[.stock], 125_000)
    }

    // MARK: - Edge cases

    /// Zero cost basis — caller-facing ROI must be `nil`, sums still
    /// computed normally. Models a freshly-gifted position.
    /// 100 × $10 = $1000 → 100_000 cents.
    func test_zeroCostBasis_roiIsNil() {
        let asset = makeAsset(currency: "USD")
        let holding = makeHolding(
            assetId: asset.id, ticker: "GIFT", kind: .stock,
            quantity: 100, costBasis: 0, lastPrice: 10
        )

        let result = PortfolioCalculator.aggregate(
            holdings: [holding],
            assetsById: [asset.id: asset],
            fxRates: ["USD": 1.0],
            baseCurrency: .usd
        )

        XCTAssertEqual(result.totalValue, 100_000)
        XCTAssertEqual(result.totalCostBasis, 0)
        XCTAssertEqual(result.unrealizedPnL, 100_000)
        XCTAssertNil(result.roi)
    }

    /// Holding's parent asset is missing from the map → silently skipped.
    /// Should never happen with FK in place, but the calculator must not
    /// crash on a stale/inconsistent fetch.
    func test_missingParentAsset_isSkippedSilently() {
        let holding = makeHolding(
            assetId: "ghost-asset",
            quantity: 100, costBasis: 100_00, lastPrice: 10
        )

        let result = PortfolioCalculator.aggregate(
            holdings: [holding],
            assetsById: [:],
            fxRates: ["USD": 1.0],
            baseCurrency: .usd
        )

        XCTAssertEqual(result, .zero)
    }

    /// Negative ROI when current price has fallen below cost basis.
    /// 100 × $50 = $5000 → 500_000 cents; cost $100,000 → 10_000_000 cents.
    func test_lossPosition_negativeROI() {
        let asset = makeAsset(currency: "USD")
        let holding = makeHolding(
            assetId: asset.id, ticker: "DOWN", kind: .stock,
            quantity: 100, costBasis: 10_000_000, lastPrice: 50
        )

        let result = PortfolioCalculator.aggregate(
            holdings: [holding],
            assetsById: [asset.id: asset],
            fxRates: ["USD": 1.0],
            baseCurrency: .usd
        )

        XCTAssertEqual(result.totalValue, 500_000)
        XCTAssertEqual(result.totalCostBasis, 10_000_000)
        XCTAssertEqual(result.unrealizedPnL, -9_500_000)
        XCTAssertEqual(result.roi, Decimal(string: "-0.95"))
    }

    // MARK: - Multi-currency

    /// USD asset + EUR asset, base = USD. EUR is 0.9 per USD (rates map
    /// uses USD pivot, so rates["EUR"] = "EUR per USD"). Verifies that
    /// `byCurrency` keys keep the *parent asset's* currency (for the
    /// exposure chart), not the base.
    func test_crossCurrency_aggregatesIntoBaseAndKeepsExposure() {
        let usdAsset = makeAsset(currency: "USD")
        let eurAsset = makeAsset(currency: "EUR")

        // VOO 10 × $500 = $5000 → 500_000 cents; cost $4000 → 400_000 cents.
        let usdH = makeHolding(
            assetId: usdAsset.id, ticker: "VOO", kind: .etf,
            quantity: 10, costBasis: 400_000, lastPrice: 500
        )
        // VWCE 5 × €100 = €500 → 50_000 cents; cost €400 → 40_000 cents.
        let eurH = makeHolding(
            assetId: eurAsset.id, ticker: "VWCE", kind: .etf,
            quantity: 5, costBasis: 40_000, lastPrice: 100
        )

        let result = PortfolioCalculator.aggregate(
            holdings: [usdH, eurH],
            assetsById: [usdAsset.id: usdAsset, eurAsset.id: eurAsset],
            fxRates: ["USD": 1.0, "EUR": 0.9],
            baseCurrency: .usd
        )

        // USD part: 5000 USD = 500_000 cents.
        // EUR part converted to USD: 500 EUR * (1/0.9) ≈ 555.55 USD ≈ 55_556 cents.
        let convertedEUR = NetWorthCalculator.convert(
            amount: 50_000,
            from: "EUR",
            to: "USD",
            rates: ["USD": 1.0, "EUR": 0.9]
        )
        XCTAssertEqual(result.totalValue, 500_000 + convertedEUR)

        // Exposure chart shows native currencies, summed in base currency cents.
        XCTAssertEqual(result.byCurrency["USD"], 500_000)
        XCTAssertEqual(result.byCurrency["EUR"], convertedEUR)
    }

    // MARK: - Per-holding ROI helper

    func test_roi_helper_zeroCostBasis_returnsNil() {
        let h = makeHolding(
            assetId: "a", quantity: 10, costBasis: 0, lastPrice: 100
        )
        XCTAssertNil(PortfolioCalculator.roi(for: h))
    }

    func test_roi_helper_positiveReturn() {
        let h = makeHolding(
            assetId: "a", quantity: 10, costBasis: 100_00, lastPrice: 20
        )
        // value = 10 * 20 * 100 = 200_00; cost = 100_00; roi = 1.0
        XCTAssertEqual(PortfolioCalculator.roi(for: h), 1)
    }

    // MARK: - Stale price flag

    /// `lastPriceDate` more than 30 days behind today → `isStale` true.
    func test_isStale_oldPrice() {
        let h = InvestmentHolding(
            id: "h1", userId: "u", assetId: "a",
            ticker: "VOO", kind: .etf, quantity: 1,
            costBasis: 100_00, lastPrice: 100,
            lastPriceDate: "2026-01-01"
        )
        let today = NetWorthSnapshotRepository.dateFormatter.date(from: "2026-04-29")!
        XCTAssertTrue(h.isStale(asOf: today))
    }

    func test_isStale_recentPrice() {
        let h = InvestmentHolding(
            id: "h1", userId: "u", assetId: "a",
            ticker: "VOO", kind: .etf, quantity: 1,
            costBasis: 100_00, lastPrice: 100,
            lastPriceDate: "2026-04-15"
        )
        let today = NetWorthSnapshotRepository.dateFormatter.date(from: "2026-04-29")!
        XCTAssertFalse(h.isStale(asOf: today))
    }

    // MARK: - Rebalance

    /// Allocation already matches target → no actions.
    func test_rebalance_alreadyOnTarget_noActions() {
        let summary = PortfolioCalculator.Summary(
            totalValue: 1_000_00,
            totalCostBasis: 1_000_00,
            unrealizedPnL: 0,
            roi: 0,
            byKind: [.etf: 700_00, .stock: 300_00],
            byCurrency: [:]
        )
        let actions = PortfolioCalculator.rebalance(
            summary: summary,
            target: [.etf: Decimal(string: "0.7")!, .stock: Decimal(string: "0.3")!]
        )
        XCTAssertTrue(actions.isEmpty)
    }

    /// Underweight kind → emits a buy action.
    /// 60/40 actual, 70/30 target — buy ETF until ETF/total = 70%
    /// without selling stock. Stock stays at 400, target weight 0.3
    /// → required total = 400/0.3 ≈ 1333.33, buy ETF = 1333.33*0.7 - 600 ≈ 333.
    func test_rebalance_underweightETF_buyAction() {
        let summary = PortfolioCalculator.Summary(
            totalValue: 1_000_00,
            totalCostBasis: 1_000_00,
            unrealizedPnL: 0,
            roi: 0,
            byKind: [.etf: 600_00, .stock: 400_00],
            byCurrency: [:]
        )
        let actions = PortfolioCalculator.rebalance(
            summary: summary,
            target: [.etf: Decimal(string: "0.7")!, .stock: Decimal(string: "0.3")!]
        )
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.kind, .etf)
        XCTAssertGreaterThan(actions.first?.buyAmountMinor ?? 0, 30_000)
        XCTAssertLessThan(actions.first?.buyAmountMinor ?? 0, 35_000)
    }

    /// Missing kind in current allocation (ZERO weight) → buy action
    /// emitted regardless of tolerance.
    func test_rebalance_missingKind_alwaysSuggested() {
        let summary = PortfolioCalculator.Summary(
            totalValue: 1_000_00,
            totalCostBasis: 1_000_00,
            unrealizedPnL: 0,
            roi: 0,
            byKind: [.etf: 1_000_00],
            byCurrency: [:]
        )
        // Add a small bond target that's missing entirely.
        let actions = PortfolioCalculator.rebalance(
            summary: summary,
            target: [
                .etf: Decimal(string: "0.95")!,
                .bond: Decimal(string: "0.05")!,
            ]
        )
        XCTAssertTrue(actions.contains { $0.kind == .bond })
    }

    /// Overweight kinds get no action — we never sell.
    func test_rebalance_overweight_noSellAction() {
        let summary = PortfolioCalculator.Summary(
            totalValue: 1_000_00,
            totalCostBasis: 1_000_00,
            unrealizedPnL: 0,
            roi: 0,
            byKind: [.etf: 800_00, .stock: 200_00],
            byCurrency: [:]
        )
        // Target says ETF should be 50% but it's already 80%.
        let actions = PortfolioCalculator.rebalance(
            summary: summary,
            target: [.etf: Decimal(string: "0.5")!, .stock: Decimal(string: "0.5")!]
        )
        // Only stock action (buy more stock); never an ETF sell.
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.kind, .stock)
    }

    /// Empty portfolio → no actions (avoid div0).
    func test_rebalance_emptyPortfolio_noActions() {
        let actions = PortfolioCalculator.rebalance(
            summary: .zero,
            target: [.etf: 1]
        )
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - CAGR

    /// Cost basis 0 → nil. Avoid div0.
    func test_cagr_zeroCostBasis_returnsNil() {
        let h = makeHolding(assetId: "a", quantity: 10, costBasis: 0, lastPrice: 100)
        let acquired = Date(timeIntervalSinceNow: -365 * 86400)
        XCTAssertNil(PortfolioCalculator.cagr(for: h, acquiredDate: acquired))
    }

    /// Acquired in the future → nil.
    func test_cagr_futureAcquired_returnsNil() {
        let h = makeHolding(assetId: "a", quantity: 10, costBasis: 100_00, lastPrice: 110)
        let future = Date(timeIntervalSinceNow: 86400)
        XCTAssertNil(PortfolioCalculator.cagr(for: h, acquiredDate: future))
    }

    /// Held less than 30 days → nil (annualizing 2-week return is bunk).
    func test_cagr_tooShortHistory_returnsNil() {
        let h = makeHolding(assetId: "a", quantity: 10, costBasis: 100_00, lastPrice: 110)
        let recent = Date(timeIntervalSinceNow: -10 * 86400)
        XCTAssertNil(PortfolioCalculator.cagr(for: h, acquiredDate: recent))
    }

    /// 1.21× return over 1.0 yr → CAGR ≈ +21%.
    /// Held: $1000 cost, value $1210 (10 × $121).
    func test_cagr_oneYearTwentyPct_returnsAbout21pct() {
        let h = makeHolding(assetId: "a", quantity: 10, costBasis: 100_000, lastPrice: 121)
        let oneYear = Date(timeIntervalSinceNow: -365.25 * 86400)
        let cagr = PortfolioCalculator.cagr(for: h, acquiredDate: oneYear)!
        let pct = NSDecimalNumber(decimal: cagr).doubleValue
        XCTAssertEqual(pct, 0.21, accuracy: 0.01)
    }

    /// 1.0 ratio over 2 years → CAGR = 0% (no growth).
    func test_cagr_flatTwoYears_returnsZero() {
        let h = makeHolding(assetId: "a", quantity: 10, costBasis: 100_000, lastPrice: 100)
        let twoYears = Date(timeIntervalSinceNow: -2 * 365.25 * 86400)
        let cagr = PortfolioCalculator.cagr(for: h, acquiredDate: twoYears)!
        let pct = NSDecimalNumber(decimal: cagr).doubleValue
        XCTAssertEqual(pct, 0.0, accuracy: 0.001)
    }
}
