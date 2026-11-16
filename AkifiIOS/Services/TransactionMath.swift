import Foundation

/// Pure helpers for turning per-transaction amounts into comparable,
/// single-currency numbers.
///
/// ADR-001 keeps `Transaction.amountNative` in the owning account's
/// currency. Any aggregation that spans multiple accounts with different
/// currencies must FX-normalize first — otherwise a $100 row and a 100 ₽
/// row get summed as if they were the same.
///
/// These helpers are deliberately free-standing so they can be used from
/// value-type ViewModels, free-function engines (InsightEngine etc.) and
/// the DataStore itself without an awkward dependency on `@Observable`
/// classes.
enum TransactionMath {

    /// Bundle of everything needed to FX-normalize a transaction into a
    /// target currency. Same shape as `DataStore.currencyContext`, so a
    /// caller holding a `DataStore` can pass it in directly.
    typealias CurrencyContext = (
        accountsById: [String: Account],
        fxRates: [String: Decimal],
        baseCode: String
    )

    /// Convert `tx.amountNative` into the caller's base currency.
    ///
    /// - `accountsById`: a `[accountId: Account]` lookup so the function
    ///   can find each transaction's account currency.
    /// - `fxRates`: `CurrencyManager.rates` (USD-pivoted) already mapped
    ///   to `Decimal` at the call site.
    /// - `baseCode`: uppercase ISO code of the target currency.
    ///
    /// Rows with `tx.accountId == nil` fall back to base currency (they
    /// live in "floating" space).
    static func amountInBase(
        _ tx: Transaction,
        accountsById: [String: Account],
        fxRates: [String: Decimal],
        baseCode: String
    ) -> Int64 {
        let accountCcy = tx.accountId
            .flatMap { accountsById[$0]?.currency.uppercased() }
            ?? baseCode
        return NetWorthCalculator.convert(
            amount: tx.amountNative,
            from: accountCcy,
            to: baseCode,
            rates: fxRates
        )
    }

    /// Write-path FX conversion (M3): `amount` in `from` → main units of
    /// `to`, rounded to what `to` can store (`MoneyRounding`).
    ///
    /// Unlike the read-path helpers (which fall back 1:1 so a cold start
    /// still renders *something*), a write must never guess: a missing rate
    /// used to store 100 USD on a KZT account as "100 ₸" with fx_rate = 1,
    /// and that row stays wrong forever. Missing / zero rate → throws
    /// `MissingFXRateError`; the form shows it and saves nothing.
    ///
    /// `rates` are USD-pivoted (`CurrencyManager.rates`: 1 USD = X).
    static func convertForStorage(
        _ amount: Decimal,
        from: String,
        to: String,
        rates: [String: Double]
    ) throws -> Decimal {
        let src = from.uppercased()
        let dst = to.uppercased()
        if src == dst { return MoneyRounding.roundedForStorage(amount, currency: dst) }
        guard let fromRate = rates[src], fromRate > 0, fromRate.isFinite,
              let toRate = rates[dst], toRate > 0, toRate.isFinite else {
            throw MissingFXRateError(from: src, to: dst)
        }
        let converted = amount
            / MoneyRounding.decimal(fromJSONNumber: fromRate)
            * MoneyRounding.decimal(fromJSONNumber: toRate)
        return MoneyRounding.roundedForStorage(converted, currency: dst)
    }

    /// Decimal variant for callers that work in `displayAmount` (main
    /// units, not kopecks).
    static func amountInBaseDisplay(
        _ tx: Transaction,
        accountsById: [String: Account],
        fxRates: [String: Decimal],
        baseCode: String
    ) -> Decimal {
        let kopecks = amountInBase(
            tx,
            accountsById: accountsById,
            fxRates: fxRates,
            baseCode: baseCode
        )
        return Decimal(kopecks) / 100
    }
}

/// A cross-currency entry could not be converted because the FX table has
/// no usable rate for one side. Saving is refused (M3) — see
/// `TransactionMath.convertForStorage`.
struct MissingFXRateError: LocalizedError, Equatable, Sendable {
    let from: String
    let to: String

    var errorDescription: String? {
        String(format: String(localized: "fx.error.missingRate"), from, to)
    }
}
