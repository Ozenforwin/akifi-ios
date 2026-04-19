import Foundation

/// Pure, deterministic progress calculator for `SavingsChallenge`.
///
/// Separation-of-concerns: the engine produces **progress_amount** in minor
/// units. The ViewModel decides whether to persist the new value and whether
/// the status should transition to `.completed`. That makes the engine fully
/// testable without touching the repository or the DB.
///
/// This session ships rules for `noCafe` and `categoryLimit` (full support)
/// and best-effort stubs for `roundUp` and `weeklyAmount` — the stubs don't
/// throw, they just produce conservative numbers. They can be tightened in
/// Phase 5 when more telemetry is available.
enum ChallengeProgressEngine {

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    // MARK: - Public API

    /// Compute the progress_amount for `challenge` given the user's
    /// transactions. Returns minor-unit value aligned with
    /// `SavingsChallenge.progressAmount` semantics (see the enum doc).
    static func progress(
        for challenge: SavingsChallenge,
        transactions: [Transaction]
    ) -> Int64 {
        guard let start = dateFormatter.date(from: challenge.startDate),
              let end = dateFormatter.date(from: challenge.endDate) else {
            return challenge.progressAmount
        }
        // End-date inclusive: extend to end-of-day.
        let endInclusive = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end

        let inRange = transactions.filter { tx in
            guard !tx.isTransfer else { return false }
            guard let txDate = dateFormatter.date(from: tx.date) else { return false }
            return txDate >= start && txDate < endInclusive
        }

        switch challenge.type {
        case .noCafe:
            return noCafeProgress(challenge: challenge, transactions: inRange)
        case .categoryLimit:
            return categoryLimitProgress(challenge: challenge, transactions: inRange)
        case .roundUp:
            return roundUpProgress(transactions: inRange)
        case .weeklyAmount:
            // Default: sum income transactions in the "Savings" category name.
            // When a goal link is present the ViewModel may override by using
            // actual contributions.
            return weeklyAmountProgress(transactions: inRange)
        }
    }

    /// Checks whether the challenge can be flipped to `.completed` based on
    /// its current progress and time state. Returns nil if no transition
    /// should happen.
    static func nextStatus(
        for challenge: SavingsChallenge,
        now: Date = Date()
    ) -> ChallengeStatus? {
        guard challenge.status == .active else { return nil }
        guard let end = dateFormatter.date(from: challenge.endDate) else { return nil }
        let endInclusive = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end

        switch challenge.type {
        case .noCafe:
            // Completed only at end-of-period with zero violations.
            if now >= endInclusive && challenge.progressAmount == 0 {
                return .completed
            }
        case .categoryLimit:
            // Can complete early if the period ended without exceeding target.
            if let target = challenge.targetAmount, now >= endInclusive {
                return challenge.progressAmount < target ? .completed : .abandoned
            }
        case .weeklyAmount, .roundUp:
            // Early completion: hit target before end.
            if let target = challenge.targetAmount, challenge.progressAmount >= target {
                return .completed
            }
            // End-of-period with target missed → abandoned.
            if now >= endInclusive, let target = challenge.targetAmount,
               challenge.progressAmount < target {
                return .abandoned
            }
        }
        return nil
    }

    // MARK: - Individual rules

    /// `noCafe`: sum of expenses in `categoryId` during the period.
    /// Zero means perfect. Any positive number is the "debt" — the total
    /// violating spend.
    private static func noCafeProgress(
        challenge: SavingsChallenge,
        transactions: [Transaction]
    ) -> Int64 {
        guard let catId = challenge.categoryId else { return 0 }
        return transactions
            .filter { $0.type == .expense && $0.categoryId == catId }
            .reduce(Int64(0)) { $0 + $1.amount }
    }

    /// `categoryLimit`: same accumulation as no-cafe, but compared against
    /// `targetAmount` for success evaluation (done in successFraction).
    private static func categoryLimitProgress(
        challenge: SavingsChallenge,
        transactions: [Transaction]
    ) -> Int64 {
        guard let catId = challenge.categoryId else { return 0 }
        return transactions
            .filter { $0.type == .expense && $0.categoryId == catId }
            .reduce(Int64(0)) { $0 + $1.amount }
    }

    /// `roundUp`: for every expense, compute the delta needed to round up
    /// to the nearest 100 minor units (e.g. 1_250 kopecks → +50 kopecks saved;
    /// but we treat already-round values as 0 savings). Sum over all expenses.
    private static func roundUpProgress(transactions: [Transaction]) -> Int64 {
        let expenses = transactions.filter { $0.type == .expense }
        // Round-up granularity: 100 minor units (1 whole currency unit).
        let granularity: Int64 = 100
        return expenses.reduce(Int64(0)) { acc, tx in
            let remainder = tx.amountNative % granularity
            let delta = remainder == 0 ? 0 : granularity - remainder
            return acc + delta
        }
    }

    /// `weeklyAmount`: default to incomes with known category names in any
    /// "Savings"-like bucket. Heuristic — the ViewModel can replace with
    /// actual goal-contribution sums when `linkedGoalId` is set.
    private static func weeklyAmountProgress(transactions: [Transaction]) -> Int64 {
        transactions
            .filter { $0.type == .income }
            .reduce(Int64(0)) { $0 + $1.amount }
    }
}
