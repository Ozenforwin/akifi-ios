import Foundation

/// Pure, testable service that attempts to match a newly-created `Transaction`
/// to one of the user's active `SubscriptionTracker`s.
///
/// Scoring (max 100):
///   * Amount      — 50 pts — currency match (after NULL → baseCode normalisation),
///                            amount within ±5 %. If the tx and sub currencies
///                            differ but FX rates are available, the tx amount is
///                            FX-converted into the sub's currency before the
///                            ±5 % comparison — so a 668 RUB-eq charge can still
///                            match a $9 USD subscription.
///   * Date        — 30 pts — linear: `30 * (1 - daysDiff / windowDays)` inside a ±7-day window.
///   * Merchant    — 20 pts — case-insensitive substring match between
///                             `tx.merchantName` (or `description`) and `sub.serviceName`.
///
/// A candidate is a *match* iff `score >= 60`. If several subscriptions clear
/// the threshold, the highest-scoring one wins (ties → first in input order).
enum SubscriptionMatcher {

    // MARK: - Configuration

    /// Minimum total score required to declare a match.
    static let matchThreshold: Int = 60

    /// Maximum fractional amount delta (5 %) to still award the amount component.
    static let amountTolerance: Double = 0.05

    /// Half-width of the date proximity window, in days.
    static let dateWindowDays: Int = 7

    // MARK: - Result

    struct Match: Sendable {
        let subscription: SubscriptionTracker
        let score: Int

        /// Break-down for debugging / analytics.
        let amountScore: Int
        let dateScore: Int
        let merchantScore: Int
    }

    // MARK: - Public API

    /// Evaluate a single subscription candidate against a transaction.
    /// Returns the total score (0…100) and its break-down.
    ///
    /// - Parameters:
    ///   - fxRates: USD-pivoted rate dictionary, same shape as
    ///              `CurrencyManager.rates` already cast to `Double`. Used to
    ///              cross-currency match when tx and sub currencies differ.
    ///              Empty dictionary disables FX conversion (legacy behaviour).
    ///   - baseCode: User's "data currency" used when either side has a
    ///              `nil`/empty currency string — common for legacy rows where
    ///              the transaction was written before per-row currency labels
    ///              were enforced.
    static func score(
        transaction: Transaction,
        subscription: SubscriptionTracker,
        now: Date = Date(),
        calendar: Calendar = .current,
        fxRates: [String: Double] = [:],
        baseCode: String = "RUB"
    ) -> (total: Int, amount: Int, date: Int, merchant: Int) {
        // Precondition: only expense transactions can match.
        guard transaction.type == .expense else { return (0, 0, 0, 0) }

        // --- Amount (50) ---
        // Both amounts are in minor units (kopecks). Require positive sub.amount
        // to avoid div-by-zero.
        let amountScore: Int = {
            guard subscription.amount > 0 else { return 0 }
            // NULL / empty → fall back to user's data currency, so legacy rows
            // with `currency = NULL` can still match.
            let baseUpper = baseCode.uppercased()
            let normalize: (String?) -> String = { value in
                let trimmed = value?.uppercased().trimmingCharacters(in: .whitespaces) ?? ""
                return trimmed.isEmpty ? baseUpper : trimmed
            }
            let subCurrency = normalize(subscription.currency)
            let txCurrency = normalize(transaction.currency)

            // Same currency: straightforward ±5 % delta.
            if subCurrency == txCurrency {
                let delta = abs(Double(transaction.amountNative) - Double(subscription.amount))
                let ratio = delta / Double(subscription.amount)
                return ratio <= amountTolerance ? 50 : 0
            }

            // Cross-currency: try FX conversion when rates are provided.
            guard let convertedTx = convert(
                amount: transaction.amountNative,
                from: txCurrency,
                to: subCurrency,
                fxRates: fxRates
            ) else {
                return 0
            }
            // Both sides are normalized to `subCurrency` minor units now —
            // `convertedTx` came out of FX conversion, `subscription.amount`
            // is the canonical Int64 kopecks on `SubscriptionTracker` (not
            // `Transaction.amount`; ADR-001 guards apply to txn rows only).
            let subAmount = Double(subscription.amount)
            let delta = abs(Double(convertedTx) - subAmount)
            let ratio = delta / subAmount
            return ratio <= amountTolerance ? 50 : 0
        }()

        // --- Date proximity (30) ---
        let dateScore: Int = {
            guard let nextStr = subscription.nextPaymentDate,
                  let nextDate = SubscriptionDateEngine.parseDbDate(nextStr),
                  let txDate = SubscriptionDateEngine.parseDbDate(transaction.date) else {
                return 0
            }
            let days = abs(calendar.dateComponents([.day], from: txDate, to: nextDate).day ?? Int.max)
            guard days <= dateWindowDays else { return 0 }
            let fraction = 1.0 - Double(days) / Double(dateWindowDays)
            return Int((30.0 * fraction).rounded())
        }()

        // --- Merchant / description (20) ---
        let merchantScore: Int = {
            let needle = subscription.serviceName.lowercased().trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return 0 }
            let haystacks: [String] = [
                transaction.merchantName ?? "",
                transaction.merchantFuzzy ?? "",
                transaction.description ?? ""
            ].map { $0.lowercased() }

            // Either direction counts — e.g. "spotify" in "SPOTIFY P12345"
            // or "google" service with tx merchant "google cloud".
            let matched = haystacks.contains { h in
                guard !h.isEmpty else { return false }
                return h.contains(needle) || needle.contains(h)
            }
            return matched ? 20 : 0
        }()

        let total = amountScore + dateScore + merchantScore
        return (total, amountScore, dateScore, merchantScore)
    }

    /// Find the best matching subscription for a transaction, if any crosses
    /// the threshold. `candidates` is expected to already be filtered to
    /// **active** subscriptions — but we re-check status here defensively.
    /// `fxRates`/`baseCode` are forwarded to `score(...)` so cross-currency
    /// candidates are still scored when rates are available.
    static func bestMatch(
        for transaction: Transaction,
        in candidates: [SubscriptionTracker],
        now: Date = Date(),
        calendar: Calendar = .current,
        fxRates: [String: Double] = [:],
        baseCode: String = "RUB"
    ) -> Match? {
        guard transaction.type == .expense else { return nil }

        let scored: [Match] = candidates.compactMap { sub in
            guard sub.status == .active else { return nil }
            let (total, a, d, m) = score(
                transaction: transaction,
                subscription: sub,
                now: now,
                calendar: calendar,
                fxRates: fxRates,
                baseCode: baseCode
            )
            guard total >= matchThreshold else { return nil }
            return Match(subscription: sub, score: total, amountScore: a, dateScore: d, merchantScore: m)
        }

        // Highest score wins; stable — first candidate kept on ties.
        return scored.max(by: { $0.score < $1.score })
    }

    // MARK: - FX helper

    /// Convert an integer minor-unit amount from one ISO currency to another
    /// using USD-pivoted rates (same shape as `CurrencyManager.rates`).
    /// Returns `nil` when either rate is missing or non-positive — caller is
    /// expected to fall through to a 0 amount score in that case.
    private static func convert(
        amount: Int64,
        from: String,
        to: String,
        fxRates: [String: Double]
    ) -> Int64? {
        if from == to { return amount }
        guard let fromRate = fxRates[from], fromRate > 0,
              let toRate = fxRates[to], toRate > 0 else { return nil }
        // USD-pivoted: amount / fromRate → USD-equivalent, then * toRate → target.
        return Int64(Double(amount) / fromRate * toRate)
    }
}
