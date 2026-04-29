import Foundation

/// Pure decision helpers used by the transaction form to ask the user
/// for confirmation in suspicious situations (e.g. accidentally typing
/// 350 000 ₽ instead of 350 000 ₫). Kept free of `@Observable` /
/// SwiftUI dependencies so the logic can be unit-tested in isolation.
///
/// The single trigger today — `shouldConfirmLargeExpense` — flags
/// expenses whose FX-normalized amount blows past 5× the user's
/// 30-day median per-transaction expense. We compare per-transaction
/// (not daily totals) because the user's mental model is "is this
/// one purchase weirdly big", not "did I overspend today".
enum TransactionGuards {

    // MARK: - Tunables

    /// Multiplier over the 30-day median that triggers the prompt.
    /// 5× is loose enough to skip routine outliers (e.g. a once-a-month
    /// rent payment after 30 days of café spending) while still catching
    /// the order-of-magnitude currency-mismatch errors this guard is
    /// designed to prevent.
    static let largeExpenseMultiplier: Decimal = 5

    /// Floor in **base currency** (main units, e.g. RUB ≈ 100 ₽). Stops
    /// the guard from firing on noise: if the user's median is 50 ₽
    /// (test data, freshly imported), 300 ₽ is technically 6× but not
    /// suspicious. Tunable — bump if QA still sees false positives.
    static let largeExpenseMinThreshold: Decimal = 100

    /// Lookback window for the median, in days. 30 d covers a typical
    /// monthly spending cycle (rent, groceries, subscriptions) so the
    /// median reflects the user's usual purchase size, not a stale
    /// post-onboarding average.
    static let medianLookbackDays: Int = 30

    // MARK: - Decision

    /// Outcome bundle so callers can render the alert message ("you
    /// usually spend ≈ X") without recomputing the median.
    struct LargeExpenseDecision: Equatable {
        let shouldConfirm: Bool
        /// Median per-transaction expense in base currency, main units.
        /// Always populated so the caller can format `"≈ X"` even when
        /// `shouldConfirm == false` (cheap to compute, simpler API).
        let medianInBaseDisplay: Decimal
        /// The input amount FX-normalized to base currency, main units.
        /// `nil` when no FX rate is available for the entered currency
        /// — guard short-circuits to `false` in that case.
        let inputInBaseDisplay: Decimal?
    }

    /// Decide whether the form should show a "Confirm large expense"
    /// alert before saving.
    ///
    /// Trigger condition (all must hold):
    ///   1. `type == .expense` — income can legitimately be huge.
    ///   2. `inputInBase > 5 × median30d` — strictly greater, so
    ///      ordinary "exactly 5×" doesn't surprise the user.
    ///   3. `inputInBase >= 100` (base, main units) — kills false
    ///      positives on tiny medians.
    ///   4. `median30d > 0` — no history → no opinion.
    ///   5. FX rate for `inputCurrency` is available (else we'd be
    ///      comparing apples to oranges and could nag every save).
    ///
    /// - Parameters:
    ///   - inputAmount: raw user-entered Decimal (main units of
    ///     `inputCurrency`, NOT kopecks). Already validated > 0 by
    ///     the form before this is called.
    ///   - inputCurrency: ISO code of the user's entry currency.
    ///   - type: transaction type from the form selector.
    ///   - allTransactions: full list (DataStore.transactions). The
    ///     function filters internally — caller doesn't need to pre-
    ///     trim to expenses or to the lookback window.
    ///   - context: `(accountsById, fxRates, baseCode)` from
    ///     `DataStore.currencyContext` (or constructed manually in
    ///     tests). `fxRates` are USD-pivoted Decimal multipliers; same
    ///     contract as `TransactionMath.amountInBase`.
    ///   - now: clock injection point for tests. Defaults to current
    ///     wall time.
    ///
    /// - Returns: `LargeExpenseDecision` — see field docs.
    static func shouldConfirmLargeExpense(
        inputAmount: Decimal,
        inputCurrency: String,
        type: TransactionType,
        allTransactions: [Transaction],
        context: TransactionMath.CurrencyContext,
        now: Date = Date()
    ) -> LargeExpenseDecision {
        // 1. Income / transfer never trigger — short-circuit so we
        //    don't even compute the median.
        guard type == .expense else {
            return LargeExpenseDecision(
                shouldConfirm: false,
                medianInBaseDisplay: 0,
                inputInBaseDisplay: nil
            )
        }

        // 2. FX-normalize the user's input to base currency. Missing
        //    rate → bail out (we can't compare honestly).
        guard let inputInBase = normalizeToBase(
            amount: inputAmount,
            fromCurrency: inputCurrency,
            fxRates: context.fxRates,
            baseCode: context.baseCode
        ) else {
            return LargeExpenseDecision(
                shouldConfirm: false,
                medianInBaseDisplay: 0,
                inputInBaseDisplay: nil
            )
        }

        // 3. Compute the per-transaction expense median over the
        //    lookback window, in base currency.
        let median = medianExpenseInBase(
            transactions: allTransactions,
            context: context,
            now: now,
            lookbackDays: medianLookbackDays
        )

        // 4. Apply the four guards. `>` (strict) on the multiplier so
        //    a "spend 5× the median" edge case isn't treated as a
        //    surprise — tests pin this contract.
        let shouldConfirm = median > 0
            && inputInBase >= largeExpenseMinThreshold
            && inputInBase > median * largeExpenseMultiplier

        return LargeExpenseDecision(
            shouldConfirm: shouldConfirm,
            medianInBaseDisplay: median,
            inputInBaseDisplay: inputInBase
        )
    }

    // MARK: - Helpers (internal so tests can poke them directly)

    /// Per-transaction expense median in base currency, main units.
    /// Uses each transaction's FX-normalized `amountNative`. Transfers
    /// and income rows are skipped — we only care about the size of a
    /// typical purchase. Returns 0 when the window has no expenses.
    static func medianExpenseInBase(
        transactions: [Transaction],
        context: TransactionMath.CurrencyContext,
        now: Date,
        lookbackDays: Int
    ) -> Decimal {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -lookbackDays,
            to: now
        ) ?? now

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        // Each entry: absolute per-transaction expense in base, main
        // units. We compute on Decimal so we can take a true median
        // without losing precision for low-decimal currencies (VND).
        var amounts: [Decimal] = []
        amounts.reserveCapacity(transactions.count)

        for tx in transactions {
            guard tx.type == .expense, tx.transferGroupId == nil else {
                continue
            }
            // Date filter: rely on the `yyyy-MM-dd` prefix in `tx.date`.
            // Falling back to "include" on parse failure would over-count
            // legacy rows; we'd rather drop them.
            guard let txDate = formatter.date(from: tx.date),
                  txDate >= cutoff else {
                continue
            }
            let kopecks = TransactionMath.amountInBase(
                tx,
                accountsById: context.accountsById,
                fxRates: context.fxRates,
                baseCode: context.baseCode
            )
            // `amountNative` is non-negative for expenses by convention,
            // but `abs()` is cheap insurance against a stray sign flip.
            let display = abs(Decimal(kopecks)) / 100
            if display > 0 {
                amounts.append(display)
            }
        }

        guard !amounts.isEmpty else { return 0 }
        amounts.sort()
        let mid = amounts.count / 2
        if amounts.count.isMultiple(of: 2) {
            return (amounts[mid - 1] + amounts[mid]) / 2
        }
        return amounts[mid]
    }

    /// Convert an arbitrary amount (in `fromCurrency`) into the user's
    /// base currency using USD-pivoted rates. Mirrors
    /// `CurrencyManager.crossConvert` semantics but takes the rate
    /// table directly so it stays pure.
    ///
    /// Returns `nil` when either rate is missing — explicit "unknown"
    /// signal so callers can choose to skip the comparison instead of
    /// silently treating 1000 VND as 1000 RUB (the bug class this
    /// whole feature exists to prevent).
    static func normalizeToBase(
        amount: Decimal,
        fromCurrency: String,
        fxRates: [String: Decimal],
        baseCode: String
    ) -> Decimal? {
        let from = fromCurrency.uppercased()
        let to = baseCode.uppercased()
        if from == to { return amount }
        guard let fromRate = fxRates[from], fromRate > 0,
              let toRate = fxRates[to], toRate > 0 else {
            return nil
        }
        return amount / fromRate * toRate
    }
}
