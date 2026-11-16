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

    /// Account types whose incoming transfers count as "set aside" for a
    /// `weeklyAmount` challenge.
    static let savingsAccountTypes: Set<AccountType> = [.savings, .deposit, .investment]

    // MARK: - Public API

    /// Compute the progress_amount for `challenge` given the user's
    /// transactions. Returns minor-unit value in the challenge's base
    /// currency (`currencyContext.baseCode`).
    ///
    /// Transactions on accounts denominated in a different currency are
    /// FX-normalized through `TransactionMath.amountInBase`. A
    /// category-limit challenge across a RUB cafe and a USD coffee shop
    /// would otherwise sum kopecks and cents as if identical.
    static func progress(
        for challenge: SavingsChallenge,
        transactions: [Transaction],
        currencyContext: TransactionMath.CurrencyContext
    ) -> Int64 {
        let start = String(challenge.startDate.prefix(10))
        let end = String(challenge.endDate.prefix(10))
        guard AppDateFormatters.day(start) != nil, AppDateFormatters.day(end) != nil else {
            return challenge.progressAmount
        }

        // Local days start ..< end (end exclusive — see SavingsChallenge).
        // `yyyy-MM-dd` strings order chronologically, and `tx.date` is the
        // user's local day, so no Date round-trip is needed.
        let inRange = transactions.filter { tx in
            let day = String(tx.date.prefix(10))
            return day >= start && day < end
        }

        switch challenge.type {
        case .noCafe:
            return noCafeProgress(challenge: challenge, transactions: inRange, currencyContext: currencyContext)
        case .categoryLimit:
            return categoryLimitProgress(challenge: challenge, transactions: inRange, currencyContext: currencyContext)
        case .roundUp:
            return roundUpProgress(transactions: inRange.filter { !$0.isTransfer })
        case .weeklyAmount:
            return weeklyAmountProgress(challenge: challenge, transactions: inRange, currencyContext: currencyContext)
        }
    }

    /// The status the challenge should move to, or nil to stay as it is.
    /// Every type resolves once the period is over (today ≥ `endDate`);
    /// target types may complete early.
    static func nextStatus(
        for challenge: SavingsChallenge,
        now: Date = Date()
    ) -> ChallengeStatus? {
        guard challenge.status == .active else { return nil }
        guard AppDateFormatters.day(challenge.endDate) != nil else { return nil }
        let finished = challenge.isFinished(now: now)

        switch challenge.type {
        case .noCafe:
            // Resolved at the end: clean → completed, any violation → failed
            // (`.abandoned`, as for a broken category limit). A violated one
            // used to stay "active" forever.
            if finished {
                return challenge.progressAmount == 0 ? .completed : .abandoned
            }
        case .categoryLimit:
            if let target = challenge.targetAmount, finished {
                return challenge.progressAmount < target ? .completed : .abandoned
            }
        case .weeklyAmount, .roundUp:
            // Early completion: hit target before end.
            if let target = challenge.targetAmount, challenge.progressAmount >= target {
                return .completed
            }
            guard finished else { return nil }
            // End of period: target missed → failed; no target (round-up is
            // optional) → whatever was saved counts as done.
            if let target = challenge.targetAmount {
                return challenge.progressAmount < target ? .abandoned : .completed
            }
            return .completed
        }
        return nil
    }

    // MARK: - Individual rules

    /// `noCafe`: sum of expenses in `categoryId` during the period,
    /// FX-normalized into the challenge's base currency.
    /// Zero means perfect. Any positive number is the "debt" — the total
    /// violating spend in base currency.
    private static func noCafeProgress(
        challenge: SavingsChallenge,
        transactions: [Transaction],
        currencyContext: TransactionMath.CurrencyContext
    ) -> Int64 {
        guard let catId = challenge.categoryId else { return 0 }
        return transactions
            .filter { !$0.isTransfer && $0.type == .expense && $0.categoryId == catId }
            .reduce(Int64(0)) { acc, tx in
                acc + TransactionMath.amountInBase(
                    tx,
                    accountsById: currencyContext.accountsById,
                    fxRates: currencyContext.fxRates,
                    baseCode: currencyContext.baseCode
                )
            }
    }

    /// `categoryLimit`: same accumulation as no-cafe, but compared against
    /// `targetAmount` for success evaluation (done in successFraction).
    private static func categoryLimitProgress(
        challenge: SavingsChallenge,
        transactions: [Transaction],
        currencyContext: TransactionMath.CurrencyContext
    ) -> Int64 {
        guard let catId = challenge.categoryId else { return 0 }
        return transactions
            .filter { !$0.isTransfer && $0.type == .expense && $0.categoryId == catId }
            .reduce(Int64(0)) { acc, tx in
                acc + TransactionMath.amountInBase(
                    tx,
                    accountsById: currencyContext.accountsById,
                    fxRates: currencyContext.fxRates,
                    baseCode: currencyContext.baseCode
                )
            }
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

    /// `weeklyAmount`: money set aside during the period.
    /// - With `categoryId`: what was booked in that category (not transfers).
    /// - Otherwise: the incoming leg of transfers into a savings, deposit or
    ///   investment account (`savingsAccountTypes`).
    /// Ordinary income never counts — "every income" used to close the
    /// challenge with the first salary. Legs may sit on differently
    /// denominated accounts, so the sum is in base currency.
    private static func weeklyAmountProgress(
        challenge: SavingsChallenge,
        transactions: [Transaction],
        currencyContext: TransactionMath.CurrencyContext
    ) -> Int64 {
        transactions
            .filter { tx in
                if let catId = challenge.categoryId {
                    return !tx.isTransfer && tx.categoryId == catId
                }
                return isSavingsInflow(tx, accountsById: currencyContext.accountsById)
            }
            .reduce(Int64(0)) { acc, tx in
                acc + TransactionMath.amountInBase(
                    tx,
                    accountsById: currencyContext.accountsById,
                    fxRates: currencyContext.fxRates,
                    baseCode: currencyContext.baseCode
                )
            }
    }

    /// The incoming leg of a user transfer into a savings-type account.
    /// Auto-transfer legs ("paid from" on shared accounts) are bookkeeping,
    /// not saving.
    static func isSavingsInflow(
        _ tx: Transaction,
        accountsById: [String: Account]
    ) -> Bool {
        guard tx.type == .income, tx.transferGroupId != nil, !tx.isAutoTransferLeg,
              let accountId = tx.accountId,
              let account = accountsById[accountId] else { return false }
        return savingsAccountTypes.contains(account.accountType)
    }
}
