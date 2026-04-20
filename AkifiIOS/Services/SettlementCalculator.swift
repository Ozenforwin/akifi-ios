import Foundation

/// Pure, stateless functions that compute who-owes-whom for a shared
/// account over a period. Two-step contract:
///   1. `compute(...)` → per-member balances (contributed, fair share, delta)
///   2. `settlements(from:)` → greedy minimum-cash-flow suggestions
///
/// All amounts are signed Int64 kopecks (minor units). The function
/// contracts don't depend on any UI or Supabase code — trivially testable.
///
/// **Custom split weights.** `account_members.split_weight` (NUMERIC(6,3))
/// drives `fairShare(M) = totalExpenses * weight(M) / sum(weights)`. If
/// `memberWeights` is empty — or every weight is equal — the math reduces
/// to equal split (`total / N`). Passing a weight of 0 is legal: that
/// member has no fair-share obligation but their contributions still
/// count (they're effectively a lender).
///
/// Settlement counts **only** expenses created via the payment-source
/// auto-transfer flow (`create_expense_with_auto_transfer`): the main
/// expense row has `auto_transfer_group_id != nil` and
/// `transfer_group_id == nil`. The paying user is credited via their
/// personal-account source leg.
///
/// Direct expenses on the shared account (no auto_transfer_group_id) and
/// legacy manual transfer pairs are **ignored**. This is intentional:
/// pulling them in would silently surface large historical debts the user
/// never opted into. To participate in settlement, the expense must be
/// created via the explicit "paid from my card" payment-source flow.
///
/// Contributions are credited by walking auto-transfer groups: the peer
/// leg of each auto-transfer on the shared account is mapped back to a
/// member via `personalAccountsByUser`. Cross-currency source legs are
/// normalized to the shared-account's base currency at read time when
/// the caller supplies `fxRates` + `baseCurrency`. Missing FX data falls
/// back to face-value — the old behavior, documented historically. A
/// follow-up migration will move to per-row stored FX to avoid snapshot
/// drift; for now we accept a small live-rate dependency.
enum SettlementCalculator {

    /// Aggregate of what a single member put into the shared account and
    /// what their fair share was for the period.
    struct MemberBalance: Sendable, Identifiable, Equatable {
        let userId: String
        /// Net contributions to the shared account via auto-transfers from
        /// this user's personal accounts. `transfer-in` minus `transfer-out`.
        let contributed: Int64
        /// This member's expected share for the period:
        /// `totalExpenses * weight(M) / sum(weights)`. With equal weights
        /// (the default) this collapses to `totalExpenses / memberCount`.
        let fairShare: Int64

        /// `contributed - fairShare`. Positive → member is owed money;
        /// negative → member owes the group.
        var delta: Int64 { contributed - fairShare }
        var id: String { userId }
    }

    /// "User A should pay User B the amount X." Direction is implicit in
    /// from/to; amount is always positive.
    struct SettlementSuggestion: Sendable, Identifiable, Equatable {
        let id: String
        let fromUserId: String
        let toUserId: String
        let amount: Int64

        init(fromUserId: String, toUserId: String, amount: Int64) {
            // Deterministic id so UI updates don't churn on recompute.
            self.id = "\(fromUserId)->\(toUserId):\(amount)"
            self.fromUserId = fromUserId
            self.toUserId = toUserId
            self.amount = amount
        }
    }

    /// Compute per-member balances for a shared account. The algorithm:
    ///
    /// 1. Find all in-period `expense` transactions on `sharedAccountId`
    ///    that are NOT transfer-legs (`transfer_group_id == nil`). These
    ///    are the actual shared-account expenditures.
    /// 2. `totalExpenses = sum(expenses)` and `fairShare = total / N`.
    /// 3. For each auto-transfer group touching this shared account,
    ///    credit/debit the member whose personal account appears as the
    ///    peer leg.
    ///
    /// - Parameters:
    ///   - sharedAccountId: the target account id to compute balances for.
    ///   - transactions: the full (unfiltered) transaction list the caller
    ///     has access to. We filter internally.
    ///   - memberUserIds: every member of the shared account. Empty array
    ///     short-circuits to `[]`.
    ///   - personalAccountsByUser: `userId → Set<personal account ids>`.
    ///     Required to attribute a transfer-leg to a member — the server
    ///     RLS will often hide other users' personal accounts, so missing
    ///     peers just get 0 contribution (delta = -fairShare).
    ///   - period: `DateInterval` — only transactions whose date falls
    ///     inside this interval count toward expenses & contributions.
    ///   - pastSettlements: settlements already marked as done for this
    ///     account. Each one adjusts contributions: `from_user` gets
    ///     credited (they paid the debt), `to_user` gets debited (they
    ///     received the repayment). This collapses closed suggestions so
    ///     they don't keep reappearing after "Отметить выполненным".
    ///     Only settlements overlapping the current period are applied.
    ///   - memberWeights: `userId → split_weight` from `account_members`.
    ///     Default empty or all-equal collapses to equal split. Members
    ///     missing from the map get weight 1.0 (backward-compat with
    ///     rows that predate the `split_weight` column).
    ///   - fxRates: USD-based currency rates (`["USD": 1.0, "RUB": 92.5, …]`)
    ///     used to normalize cross-currency source legs into the base
    ///     currency. Source: `CurrencyManager.rates`. Empty or missing
    ///     rates fall back to face-value math (legacy behavior).
    ///   - baseCurrency: ISO 4217 of the shared account. All cross-
    ///     currency contributions are converted TO this currency before
    ///     being added into `contributions`. `nil` / unknown → fall back
    ///     to face-value.
    static func compute(
        sharedAccountId: String,
        transactions: [Transaction],
        memberUserIds: [String],
        personalAccountsByUser: [String: Set<String>],
        period: DateInterval,
        pastSettlements: [Settlement] = [],
        memberWeights: [String: Decimal] = [:],
        fxRates: [String: Double] = [:],
        baseCurrency: String? = nil
    ) -> [MemberBalance] {
        guard !memberUserIds.isEmpty else { return [] }

        // Parse DB "yyyy-MM-dd" (or "yyyy-MM-dd'T'HH:mm:ss") into Date.
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        let parserFull = DateFormatter()
        parserFull.locale = Locale(identifier: "en_US_POSIX")
        parserFull.timeZone = TimeZone(identifier: "UTC")
        parserFull.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        func inPeriod(_ raw: String) -> Bool {
            let dateStr = String(raw.prefix(10))
            if let d = parser.date(from: dateStr) {
                return period.contains(d)
            }
            if let d = parserFull.date(from: raw) {
                return period.contains(d)
            }
            return false
        }

        // 1. Gather in-period rows scoped to this account.
        //    Auto-transfer expenses AND direct expenses both count toward
        //    totalExpenses. Legacy manual transfer legs (transferGroupId set
        //    but autoTransferGroupId == nil) remain ignored — they pre-
        //    date the feature and pulling them in would surface huge
        //    historical debts the user never opted into.
        let accountRows = transactions.filter {
            $0.accountId == sharedAccountId && inPeriod($0.rawDateTime.isEmpty ? $0.date : $0.rawDateTime)
        }

        // 2. Total shared-account expenses = main expense leg of each
        //    auto-transfer triplet ONLY. Direct expenses (no transfer_group_id
        //    AND no auto_transfer_group_id) and legacy manual transfer pairs
        //    are deliberately excluded — pulling them in would surface huge
        //    historical debts the user never opted into.
        let autoTransferExpenses = accountRows.filter {
            $0.type == .expense
                && $0.transferGroupId == nil
                && $0.autoTransferGroupId != nil
        }
        // Normalize each row to the caller's base currency before summing —
        // a mixed-currency shared account (e.g. some rows tagged RUB, some
        // VND) would otherwise give a meaningless total of mixed units.
        let totalExpenses: Int64 = autoTransferExpenses.reduce(0) {
            $0 + normalizeToBase(
                amount: $1.amount,
                rowCurrency: $1.currency,
                baseCurrency: baseCurrency,
                fxRates: fxRates
            )
        }

        // Resolve each member's weight, defaulting absentees to 1.0 so
        // rows that predate the split_weight migration behave as equal
        // split. We only consider members with weight > 0 for the divisor —
        // a zero-weight member has no fair-share obligation.
        let resolvedWeights: [String: Decimal] = Dictionary(
            uniqueKeysWithValues: memberUserIds.map { uid in
                (uid, memberWeights[uid] ?? 1.0)
            }
        )
        let sumWeights: Decimal = resolvedWeights.values.reduce(0, +)

        /// Fair share for a single member, in kopecks. When sumWeights is
        /// zero (every member is weight-0 — degenerate) or total is zero,
        /// everyone gets 0 and nothing is owed.
        func fairShareFor(_ uid: String) -> Int64 {
            guard totalExpenses > 0, sumWeights > 0 else { return 0 }
            let weight = resolvedWeights[uid] ?? 1.0
            let share = Decimal(totalExpenses) * weight / sumWeights
            // Round half-up to the nearest kopeck. Explicit handler
            // avoids banker's rounding drift when weights are equal.
            var rounded = Decimal()
            var source = share
            NSDecimalRound(&rounded, &source, 0, .plain)
            return Int64(truncating: rounded as NSDecimalNumber)
        }

        // 3. Contributions.
        //    Walk auto-transfer triplets (transfer_group_id AND
        //    auto_transfer_group_id both set). The peer leg on the
        //    user's personal account tells us who to credit. Source
        //    legs on a different-currency account are normalized
        //    into the shared account's base currency via `fxRates`.
        //    Direct expenses on the shared account and manual transfer
        //    pairs that predate the feature are ignored.
        var contributions: [String: Int64] = Dictionary(uniqueKeysWithValues: memberUserIds.map { ($0, 0) })

        let autoTransferLegsOnShared = accountRows.filter {
            $0.transferGroupId != nil && $0.autoTransferGroupId != nil
        }

        for row in autoTransferLegsOnShared {
            guard let groupId = row.transferGroupId else { continue }

            // Peer leg: same transfer_group_id, different account.
            let peer = transactions.first { $0.transferGroupId == groupId && $0.id != row.id }

            guard let peer, let peerAccountId = peer.accountId else {
                // Peer hidden by RLS — attribute to the row creator as best-effort.
                let uid = row.userId
                let normalized = normalizeToBase(
                    amount: row.amount,
                    rowCurrency: row.currency,
                    baseCurrency: baseCurrency,
                    fxRates: fxRates
                )
                if row.type == .income {
                    contributions[uid, default: 0] += normalized
                } else if row.type == .expense {
                    contributions[uid, default: 0] -= normalized
                }
                continue
            }

            // Attribute to whichever member's personal-account set contains the
            // peer. If not found (rare: peer is an account of a non-member or
            // a different shared account), fall back to the row creator.
            let attributedUser = personalAccountsByUser.first { _, accounts in
                accounts.contains(peerAccountId)
            }?.key ?? row.userId

            // Normalize the row amount from its source currency back to
            // base. `row` here is the leg on the shared account (target
            // currency) OR the source leg (personal currency); peer legs
            // inside the triplet live on two different currencies when
            // cross-currency. We always normalize using the row's own
            // `currency` field so the transfer-out leg (in source ccy)
            // converts correctly.
            let normalized = normalizeToBase(
                amount: row.amount,
                rowCurrency: row.currency,
                baseCurrency: baseCurrency,
                fxRates: fxRates
            )

            if row.type == .income {
                contributions[attributedUser, default: 0] += normalized
            } else if row.type == .expense {
                contributions[attributedUser, default: 0] -= normalized
            }
        }

        // 4. Apply past settlements — each closed debt adjusts both sides'
        //    contributions so the greedy pass doesn't re-suggest them.
        //    Only settlements whose period-end falls inside the current
        //    view's period are applied (different periods are independent).
        let periodDateFormatter = DateFormatter()
        periodDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        periodDateFormatter.timeZone = TimeZone(identifier: "UTC")
        periodDateFormatter.dateFormat = "yyyy-MM-dd"

        for settlement in pastSettlements {
            guard settlement.sharedAccountId == sharedAccountId else { continue }
            guard let endDate = periodDateFormatter.date(from: settlement.periodEnd),
                  period.contains(endDate) else { continue }
            contributions[settlement.fromUserId, default: 0] += settlement.amount
            contributions[settlement.toUserId, default: 0] -= settlement.amount
        }

        // 5. Clean empty state: if there are no auto-transfer expenses in the
        //    period, return an empty array so the UI shows "no feature-scoped
        //    activity yet" instead of "everyone owes each other nothing".
        if totalExpenses == 0 {
            return []
        }

        return memberUserIds.map { uid in
            MemberBalance(
                userId: uid,
                contributed: contributions[uid] ?? 0,
                fairShare: fairShareFor(uid)
            )
        }
    }

    /// Converts an `amount` (kopecks, interpreted as whatever `rowCurrency`
    /// says the row was recorded in) into `baseCurrency` kopecks using
    /// `fxRates` (USD-based). Falls back to the face-value amount when:
    /// - `rowCurrency` or `baseCurrency` is nil/unknown,
    /// - they match (no conversion needed),
    /// - any of the required rates is missing/zero.
    /// This keeps the engine robust when `CurrencyManager` hasn't loaded
    /// rates yet (cold start, offline, etc) — a small currency drift is
    /// preferable to a crash or wildly wrong settlement.
    static func normalizeToBase(
        amount: Int64,
        rowCurrency: String?,
        baseCurrency: String?,
        fxRates: [String: Double]
    ) -> Int64 {
        guard let rowCurrency, let baseCurrency else { return amount }
        let row = rowCurrency.uppercased()
        let base = baseCurrency.uppercased()
        if row == base { return amount }
        guard let fromRate = fxRates[row], fromRate != 0,
              let toRate = fxRates[base], toRate != 0
        else { return amount }
        // USD-based rates: rate[row] = rows-per-USD. To convert rows → base:
        //   base_amount = amount / fromRate * toRate.
        let decAmount = Decimal(amount)
        let decFrom = Decimal(fromRate)
        let decTo = Decimal(toRate)
        let converted = decAmount / decFrom * decTo
        var rounded = Decimal()
        var src = converted
        NSDecimalRound(&rounded, &src, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    /// Greedy min-cash-flow settlement. O(N log N) where N = member count.
    /// Result size is at most N-1 suggestions — good enough for the MVP
    /// (equal-split only).
    static func settlements(from balances: [MemberBalance]) -> [SettlementSuggestion] {
        // Ignore zero-delta members. Keep mutable copies for the greedy pass.
        var creditors = balances.filter { $0.delta > 0 }
            .sorted { $0.delta > $1.delta }
            .map { (userId: $0.userId, amount: $0.delta) }
        var debtors = balances.filter { $0.delta < 0 }
            .sorted { $0.delta < $1.delta }
            .map { (userId: $0.userId, amount: -$0.delta) }

        var out: [SettlementSuggestion] = []

        while let cred = creditors.first, let debt = debtors.first {
            let pay = min(cred.amount, debt.amount)
            if pay > 0 {
                out.append(SettlementSuggestion(fromUserId: debt.userId, toUserId: cred.userId, amount: pay))
            }

            // Reduce balances. If a side hits zero, drop it.
            creditors[0].amount -= pay
            debtors[0].amount -= pay
            if creditors[0].amount == 0 { creditors.removeFirst() }
            if debtors[0].amount == 0 { debtors.removeFirst() }
        }

        return out
    }
}
