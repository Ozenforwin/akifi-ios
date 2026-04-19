import Foundation

/// Pure, testable service that attempts to match a newly-created `Transaction`
/// to one of the user's active `SubscriptionTracker`s.
///
/// Scoring (max 100):
///   * Amount      — 50 pts — currency must match exactly, amount within ±5 %.
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
    static func score(
        transaction: Transaction,
        subscription: SubscriptionTracker,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (total: Int, amount: Int, date: Int, merchant: Int) {
        // Precondition: only expense transactions can match.
        guard transaction.type == .expense else { return (0, 0, 0, 0) }

        // --- Amount (50) ---
        // Both amounts are in minor units (kopecks). Require positive sub.amount
        // to avoid div-by-zero.
        let amountScore: Int
        if let subCurrency = subscription.currency?.uppercased(),
           let txCurrency = transaction.currency?.uppercased(),
           subCurrency == txCurrency,
           subscription.amount > 0 {
            let delta = abs(Double(transaction.amountNative) - Double(subscription.amount))
            let ratio = delta / Double(subscription.amount)
            amountScore = ratio <= amountTolerance ? 50 : 0
        } else {
            amountScore = 0
        }

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
    /// **active** subscriptions in the same currency — but we re-check here
    /// defensively.
    static func bestMatch(
        for transaction: Transaction,
        in candidates: [SubscriptionTracker],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Match? {
        guard transaction.type == .expense else { return nil }

        let scored: [Match] = candidates.compactMap { sub in
            guard sub.status == .active else { return nil }
            let (total, a, d, m) = score(
                transaction: transaction,
                subscription: sub,
                now: now,
                calendar: calendar
            )
            guard total >= matchThreshold else { return nil }
            return Match(subscription: sub, score: total, amountScore: a, dateScore: d, merchantScore: m)
        }

        // Highest score wins; stable — first candidate kept on ties.
        return scored.max(by: { $0.score < $1.score })
    }
}
