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
        // Priority for the row's native currency:
        //   1. tx.currency  — legacy label that, on TMA-imported rows, is
        //      the currency the number was actually stored in even when
        //      account.currency drifted (the «Семейный» case where the
        //      account is set to VND but most rows are RUB).
        //   2. account.currency — for fresh ADR-001 rows where the label
        //      and the account currency match by construction.
        //   3. baseCode — accountless rows (rare).
        let nativeCcy = tx.currency?.uppercased()
            ?? tx.accountId.flatMap { accountsById[$0]?.currency.uppercased() }
            ?? baseCode
        return NetWorthCalculator.convert(
            amount: tx.amountNative,
            from: nativeCcy,
            to: baseCode,
            rates: fxRates
        )
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
