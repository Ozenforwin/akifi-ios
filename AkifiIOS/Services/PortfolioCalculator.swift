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

    /// Compound Annual Growth Rate — annualized return inferred from
    /// `(currentValue / costBasis)^(1/years) − 1`, where `years` is the
    /// gap between the supplied acquired-date and `asOf`. This is *not*
    /// TWR or IRR — it ignores cash-flow timing because we only have
    /// total-position aggregates. Useful as a "what's my annualized
    /// return so far" headline number; for honest TWR we need a
    /// holding-transactions table (Phase 3).
    ///
    /// Returns nil when:
    /// * costBasis is zero,
    /// * acquired date is missing, in the future, or less than 30 days
    ///   in the past (annualizing a 2-week return is misleading),
    /// * value/costBasis ratio is non-positive (full loss, total wipe).
    static func cagr(
        for holding: InvestmentHolding,
        acquiredDate: Date?,
        asOf: Date = Date()
    ) -> Decimal? {
        guard let acquiredDate, acquiredDate < asOf else { return nil }
        let days = asOf.timeIntervalSince(acquiredDate) / 86400
        guard days >= 30 else { return nil }
        guard holding.costBasis > 0 else { return nil }

        let value = holding.currentValueMinor
        let ratio = Decimal(value) / Decimal(holding.costBasis)
        guard ratio > 0 else { return nil }

        // CAGR = ratio ^ (1 / years) − 1
        let years = days / 365.25
        let ratioD = NSDecimalNumber(decimal: ratio).doubleValue
        let annualized = pow(ratioD, 1.0 / years) - 1.0
        guard annualized.isFinite else { return nil }
        return Decimal(annualized)
    }

    // MARK: - Rebalance

    /// Single suggested action from the rebalance helper. Always
    /// "buy X on top of what you already have" (no-sell mode), so a
    /// long-term passive investor can correct drift without realising
    /// gains. Tax-aware sells live in a future tax-lot pass.
    struct RebalanceAction: Sendable, Equatable {
        let kind: HoldingKind
        /// How much to add in base-currency minor units to bring the
        /// allocation to target. Always > 0.
        let buyAmountMinor: Int64
        /// Current weight (0...1) before buying.
        let currentWeight: Decimal
        /// Target weight (0...1).
        let targetWeight: Decimal
    }

    /// No-sell rebalance plan.
    ///
    /// Strategy: figure out the *new total* needed for the most
    /// underweight kind to hit its target without selling anything,
    /// then top up every other underweight kind from current value
    /// to its share of that new total. Overweight kinds are left
    /// alone.
    ///
    /// In practice: the user buys a slug of cash, the calculator
    /// tells them how to split that slug across underweight kinds
    /// (or — no slug yet — how big the slug needs to be). Returns
    /// `[]` when allocation is already within `tolerance` of target.
    ///
    /// - Parameters:
    ///   - summary: aggregated portfolio summary (use `aggregate`).
    ///   - target: target weights per kind. Caller is responsible for
    ///     making sure the values sum to ≈ 1.0; we tolerate tiny
    ///     rounding drift.
    ///   - tolerance: ignore drift smaller than this fraction
    ///     (default 1% — UI lets the user adjust later).
    static func rebalance(
        summary: Summary,
        target: [HoldingKind: Decimal],
        tolerance: Decimal = Decimal(string: "0.01")!
    ) -> [RebalanceAction] {
        guard summary.totalValue > 0, !target.isEmpty else { return [] }

        let total = Decimal(summary.totalValue)
        // Compute current weights — kinds present in `summary.byKind`
        // get their actual weight; kinds in target but missing from
        // byKind have weight 0.
        var currentWeights: [HoldingKind: Decimal] = [:]
        for (kind, amount) in summary.byKind {
            currentWeights[kind] = Decimal(amount) / total
        }

        // Find the maximum "uplift factor" we need: max over kinds of
        // (currentValue / targetWeight). That's the new total which,
        // when each kind is multiplied by its target weight, leaves
        // every kind at least at its current value (no selling).
        var requiredTotal = total
        for (kind, w) in target where w > 0 {
            let curMinor = Decimal(summary.byKind[kind] ?? 0)
            let needed = curMinor / w
            if needed > requiredTotal { requiredTotal = needed }
        }
        let topUp = requiredTotal - total

        var actions: [RebalanceAction] = []
        for (kind, w) in target where w > 0 {
            let curMinor = Decimal(summary.byKind[kind] ?? 0)
            let targetMinor = requiredTotal * w
            let buy = targetMinor - curMinor
            guard buy > 0 else { continue }
            // Drift threshold: only emit an action if buying changes
            // weight by more than tolerance, OR the kind is missing
            // entirely (current weight 0).
            let curW = currentWeights[kind] ?? 0
            let drift = abs(curW - w)
            guard drift > tolerance || curW == 0 else { continue }
            var rounded = Decimal()
            var src = buy
            NSDecimalRound(&rounded, &src, 0, .plain)
            let buyInt = Int64(truncating: rounded as NSDecimalNumber)
            actions.append(RebalanceAction(
                kind: kind,
                buyAmountMinor: buyInt,
                currentWeight: curW,
                targetWeight: w
            ))
            _ = topUp // referenced for future analytics; kept for symmetry
        }
        // Stable order: largest buy first.
        actions.sort { $0.buyAmountMinor > $1.buyAmountMinor }
        return actions
    }
}
