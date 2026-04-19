import Foundation

/// Pure, stateless net-worth math. Given raw balances/assets/liabilities
/// in their native currencies + an FX rate map (USD-based) + a base
/// currency, produces a `Breakdown` struct with everything normalized to
/// the base currency in kopecks.
///
/// # Contract
/// - Everything is `Int64` minor units (kopecks).
/// - `fxRates[code] = "units of code per USD"` — same convention as
///   `CurrencyManager.rates` and `SettlementCalculator.normalizeToBase`.
/// - Unknown / missing rates fall back to **1:1** (no conversion). This
///   is a deliberate trade-off: never crash, never return zero; surface
///   at most a small drift until rates load.
/// - Zero-sized inputs short-circuit — no division/allocation overhead.
///
/// # Why not `Decimal` end-to-end?
/// Int64 kopecks is the canonical currency unit throughout the app. FX
/// conversion goes through `Decimal` internally (to avoid double-precision
/// drift on small rates) and only rounds back to Int64 at the boundary.
enum NetWorthCalculator {

    /// Aggregate result of a single compute-pass. Sums are in `baseCurrency`
    /// kopecks; per-category maps are keyed by the `AssetCategory` /
    /// `LiabilityCategory` enum so the UI can group with type-safety.
    struct Breakdown: Sendable {
        let accountsTotal: Int64
        let assetsTotal: Int64
        let liabilitiesTotal: Int64
        let byAssetCategory: [AssetCategory: Int64]
        let byLiabilityCategory: [LiabilityCategory: Int64]

        /// Accounts + assets − liabilities, all in base currency.
        var netWorth: Int64 { accountsTotal + assetsTotal - liabilitiesTotal }

        static let zero = Breakdown(
            accountsTotal: 0,
            assetsTotal: 0,
            liabilitiesTotal: 0,
            byAssetCategory: [:],
            byLiabilityCategory: [:]
        )
    }

    /// Compute a full breakdown.
    ///
    /// - Parameters:
    ///   - accountBalances: `(currency, amount)` pairs for every liquid
    ///     account (checking, savings, brokerage). Amount is in the
    ///     account's own currency (kopecks); the function normalizes each
    ///     to `baseCurrency` before summing.
    ///   - assets: raw `Asset` rows. Each carries its own `currency` —
    ///     normalized at sum time.
    ///   - liabilities: raw `Liability` rows. Same normalization rules.
    ///   - fxRates: `code → rate` map with `USD` as the pivot (matches
    ///     `ExchangeRateService.fetchRates(base: "USD")`). Empty map or
    ///     missing entries → 1:1 fallback.
    ///   - baseCurrency: target currency for all outputs. Normally the
    ///     user's `CurrencyManager.dataCurrency`.
    static func compute(
        accountBalances: [(accountCurrency: String, amount: Int64)],
        assets: [Asset],
        liabilities: [Liability],
        fxRates: [String: Decimal],
        baseCurrency: CurrencyCode
    ) -> Breakdown {
        let base = baseCurrency.rawValue.uppercased()

        // Accounts
        var accountsTotal: Int64 = 0
        for (ccy, amt) in accountBalances {
            accountsTotal += convert(amount: amt, from: ccy, to: base, rates: fxRates)
        }

        // Assets
        var assetsTotal: Int64 = 0
        var byAssetCategory: [AssetCategory: Int64] = [:]
        for asset in assets {
            let normalized = convert(
                amount: asset.currentValue,
                from: asset.currency,
                to: base,
                rates: fxRates
            )
            assetsTotal += normalized
            byAssetCategory[asset.category, default: 0] += normalized
        }

        // Liabilities (positive sums — caller does the sign flip in netWorth).
        var liabilitiesTotal: Int64 = 0
        var byLiabilityCategory: [LiabilityCategory: Int64] = [:]
        for liability in liabilities {
            let normalized = convert(
                amount: liability.currentBalance,
                from: liability.currency,
                to: base,
                rates: fxRates
            )
            liabilitiesTotal += normalized
            byLiabilityCategory[liability.category, default: 0] += normalized
        }

        return Breakdown(
            accountsTotal: accountsTotal,
            assetsTotal: assetsTotal,
            liabilitiesTotal: liabilitiesTotal,
            byAssetCategory: byAssetCategory,
            byLiabilityCategory: byLiabilityCategory
        )
    }

    /// Converts `amount` (kopecks, interpreted as `from` currency) into
    /// `to` currency kopecks using USD-pivot `rates`.
    ///
    /// Fallback rules (documented limitation — see hot.md):
    /// - `from == to` → passthrough.
    /// - Any rate missing or zero → **1:1 fallback** (no conversion).
    ///   This mirrors `SettlementCalculator.normalizeToBase` behavior
    ///   so FX-missing doesn't crash cold-start or offline users.
    static func convert(
        amount: Int64,
        from: String,
        to: String,
        rates: [String: Decimal]
    ) -> Int64 {
        let src = from.uppercased()
        let dst = to.uppercased()
        if src == dst { return amount }

        // USD is the pivot. USD→dst is just `rates[dst]`; src→USD is
        // `1 / rates[src]`. Both must be non-zero to make sense.
        guard let fromRate = rates[src], fromRate != 0,
              let toRate = rates[dst], toRate != 0 else {
            return amount
        }

        let decAmount = Decimal(amount)
        let converted = decAmount / fromRate * toRate

        var rounded = Decimal()
        var source = converted
        NSDecimalRound(&rounded, &source, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }
}
