import Foundation

/// Pure, stateless portfolio math. Sister of `NetWorthCalculator`:
/// given holdings + an FX rate map (USD pivot, same convention as
/// `CurrencyManager.rates`) + a target `baseCurrency`, returns a
/// `PortfolioSummary` with:
///
/// - total current market value (sum of `quantity × lastPrice`),
/// - total cost basis,
/// - unrealised P&L and ROI,
/// - breakdown by `HoldingKind` (for the allocation pie chart),
/// - breakdown by currency (for currency exposure analysis).
///
/// # Contract
/// - Sums are returned in `baseCurrency` minor units (kopecks).
/// - Per-holding values are computed in the parent Asset's currency
///   first, then converted via `NetWorthCalculator.convert(...)` so the
///   FX behaviour is identical (USD pivot, 1:1 fallback on missing rate).
/// - Empty input → all-zero summary, `roi == 0`.
/// - Zero `costBasis` for a holding → its individual ROI is reported
///   as `nil` (caller decides whether to show "—" or skip).
enum PortfolioCalculator {

    /// Aggregate result of one compute pass.
    struct Summary: Sendable, Equatable {
        let totalValue: Int64
        let totalCostBasis: Int64
        let unrealizedPnL: Int64
        /// (totalValue − totalCostBasis) / totalCostBasis, expressed as
        /// a fractional Decimal (e.g. `0.125` = +12.5%). `nil` when
        /// `totalCostBasis == 0` (avoid div-by-zero).
        let roi: Decimal?
        let byKind: [HoldingKind: Int64]
        let byCurrency: [String: Int64]

        static let zero = Summary(
            totalValue: 0,
            totalCostBasis: 0,
            unrealizedPnL: 0,
            roi: nil,
            byKind: [:],
            byCurrency: [:]
        )
    }

    /// Aggregate `holdings` into `baseCurrency`, joining each holding to
    /// its parent `Asset` to learn its native currency.
    ///
    /// - Parameters:
    ///   - holdings: every `InvestmentHolding` to include. Holdings whose
    ///     `assetId` is missing from `assetsById` are skipped silently —
    ///     they shouldn't exist in practice (FK), but a sloppy fetch race
    ///     should never crash.
    ///   - assetsById: lookup map for parent assets — provides the
    ///     currency used by each holding's `quantity × lastPrice`.
    ///     Build with `Dictionary(uniqueKeysWithValues:)` over assets.
    ///   - fxRates: `code → rate` map with USD pivot (same as
    ///     `CurrencyManager.rates`, see `NetWorthCalculator.convert`).
    ///   - baseCurrency: target currency for all sums.
    static func aggregate(
        holdings: [InvestmentHolding],
        assetsById: [String: Asset],
        fxRates: [String: Decimal],
        baseCurrency: CurrencyCode
    ) -> Summary {
        guard !holdings.isEmpty else { return .zero }

        let base = baseCurrency.rawValue.uppercased()

        var totalValue: Int64 = 0
        var totalCostBasis: Int64 = 0
        var byKind: [HoldingKind: Int64] = [:]
        var byCurrency: [String: Int64] = [:]

        for holding in holdings {
            guard let parent = assetsById[holding.assetId] else { continue }
            let parentCcy = parent.currency.uppercased()

            let nativeValue = holding.currentValueMinor
            let convertedValue = NetWorthCalculator.convert(
                amount: nativeValue,
                from: parentCcy,
                to: base,
                rates: fxRates
            )
            let convertedCost = NetWorthCalculator.convert(
                amount: holding.costBasis,
                from: parentCcy,
                to: base,
                rates: fxRates
            )

            totalValue += convertedValue
            totalCostBasis += convertedCost
            byKind[holding.kind, default: 0] += convertedValue
            byCurrency[parentCcy, default: 0] += convertedValue
        }

        let pnl = totalValue - totalCostBasis
        let roi: Decimal? = totalCostBasis == 0
            ? nil
            : Decimal(pnl) / Decimal(totalCostBasis)

        return Summary(
            totalValue: totalValue,
            totalCostBasis: totalCostBasis,
            unrealizedPnL: pnl,
            roi: roi,
            byKind: byKind,
            byCurrency: byCurrency
        )
    }

    /// Per-holding ROI in the holding's native currency. `nil` if cost
    /// basis is zero — caller renders "—" rather than infinity.
    /// Returned as a fractional `Decimal` (`0.125` = +12.5%).
    static func roi(for holding: InvestmentHolding) -> Decimal? {
        guard holding.costBasis != 0 else { return nil }
        let value = holding.currentValueMinor
        return Decimal(value - holding.costBasis) / Decimal(holding.costBasis)
    }
}
