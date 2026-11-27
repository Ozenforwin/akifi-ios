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
/// member via `personalAccountsByUser`.
///
/// **No FX.** Only rows ON the shared account are summed, and ADR-001 keeps
/// their `amountNative` in that account's currency — a cross-currency
/// payment's source leg (on the payer's card) is used to identify the payer,
/// never added. This is the local offline fallback / cross-check of the
/// server's `get_account_settlement`, which sums `amount_native` the same
/// way; the two must agree (M11 removed a label-based conversion that
/// made them differ on legacy rows).
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
    ///     RLS hides other users' personal accounts; a leg whose peer can't
    ///     be resolved is attributed to the leg's creator (the payer — the
    ///     RPC writes all three legs as the paying user).
    ///   - period: `DateInterval` — only transactions whose date falls
    ///     inside this interval count toward expenses & contributions.
    ///   - pastSettlements: settlements already marked as done for this
    ///     account. Each one adjusts contributions: `from_user` gets
    ///     credited (they paid the debt), `to_user` gets debited (they
    ///     received the repayment). This collapses closed suggestions so
    ///     they don't keep reappearing after "Отметить выполненным".
    ///     A settlement is applied when its `period_end` falls inside the
    ///     `period` argument. The production caller (`SettlementViewModel`)
    ///     passes a wide-open `distantPast..distantFuture` interval so every
    ///     settlement is applied — the balance card is always cumulative.
    ///     Period-scoped intervals are still supported for testing legacy
    ///     scenarios but are NOT used at runtime: a narrow period combined
    ///     with a wider-scoped settlement (e.g. YTD settle viewed inside a
    ///     month) inverts the in-period delta and surfaces phantom debt.
    ///   - memberWeights: `userId → split_weight` from `account_members`.
    ///     Default empty or all-equal collapses to equal split. Members
    ///     missing from the map get weight 1.0 (backward-compat with
    ///     rows that predate the `split_weight` column).
    ///   - fxRates, baseCurrency: IGNORED, kept so existing call sites
    ///     compile. Every summed row is already in the shared account's
    ///     currency (see the type doc); converting by the row's legacy
    ///     `currency` label was the M11 bug.
    static func compute(
        sharedAccountId: String,
        transactions: [Transaction],
        memberUserIds: [String],
        personalAccountsByUser: [String: Set<String>],
        period: DateInterval,
        pastSettlements: [Settlement] = [],
        transactionMemberSettlements: [TransactionMemberSettlement] = [],
        memberWeights: [String: Decimal] = [:],
        fxRates: [String: Double] = [:],
        baseCurrency: String? = nil
    ) -> [MemberBalance] {
        guard !memberUserIds.isEmpty else { return [] }

        // Parse DB "yyyy-MM-dd" (or "yyyy-MM-dd'T'HH:mm:ss") into Date.
        let parser = AppDateFormatters.utcDate
        let parserFull = AppDateFormatters.utcDateTime

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
        // Every row here lives on the shared account, so its `amountNative`
        // is already in the shared account's currency (ADR-001) — no FX.
        // M11: this used to "normalise" by the row's legacy `currency`
        // label, which on old TMA rows disagrees with the account and
        // turned a correct kopeck figure into a ×rate one. The server
        // (`get_account_settlement`) sums `amount_native` the same way.
        let totalExpenses: Int64 = autoTransferExpenses.reduce(0) { $0 + $1.amountNative } // allowlisted-amount: one shared account, one currency

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

        // Per-member fair share, in kopecks. We compute everyone's share
        // up-front so we can distribute the rounding residual (see below)
        // and guarantee `sum(fairShares) == totalExpenses`. Without that
        // step, an odd `totalExpenses` split between two equal-weight
        // members leaves a 1-kopeck residual that surfaces in the UI as
        // a "−0 ₽ должен доплатить" caption next to a "В расчёте" peer
        // (one delta exact zero, the other off by 1 kopeck).
        var fairShares: [String: Int64] = Dictionary(
            uniqueKeysWithValues: memberUserIds.map { ($0, Int64(0)) }
        )
        if totalExpenses > 0 && sumWeights > 0 {
            for uid in memberUserIds {
                let weight = resolvedWeights[uid] ?? 1.0
                let share = Decimal(totalExpenses) * weight / sumWeights
                // Round half-up to the nearest kopeck. Explicit handler
                // avoids banker's rounding drift when weights are equal.
                var rounded = Decimal()
                var source = share
                NSDecimalRound(&rounded, &source, 0, .plain)
                fairShares[uid] = Int64(truncating: rounded as NSDecimalNumber)
            }

            // Distribute residual one kopeck at a time across members in
            // the order they were passed in, so the result is deterministic
            // for tests. With 2-member equal-split the residual is at most
            // ±1; with N members and N-tier split-weights it's at most ±N/2.
            let summed = fairShares.values.reduce(0, +)
            var residual = totalExpenses - summed
            let step: Int64 = residual > 0 ? 1 : -1
            var i = 0
            while residual != 0 && i < memberUserIds.count {
                let uid = memberUserIds[i]
                fairShares[uid, default: 0] += step
                residual -= step
                i += 1
            }
        }

        // 3. Contributions.
        //    Walk auto-transfer triplets (transfer_group_id AND
        //    auto_transfer_group_id both set). The peer leg on the
        //    user's personal account tells us who to credit; only the
        //    legs on the shared account itself are summed.
        //    Direct expenses on the shared account and manual transfer
        //    pairs that predate the feature are ignored.
        var contributions: [String: Int64] = Dictionary(uniqueKeysWithValues: memberUserIds.map { ($0, 0) })

        let autoTransferLegsOnShared = accountRows.filter {
            $0.transferGroupId != nil && $0.autoTransferGroupId != nil
        }

        // Who funded an auto-transfer leg on the shared account. This ONE
        // resolver serves both the contributions walk and the per-transaction
        // marks (4b). They must never disagree: RLS hides every other member's
        // personal account, so on each phone the peer leg of the *other*
        // member's payments is invisible. When the marks walk skipped those
        // groups instead of falling back like the contributions walk did, each
        // member's phone dropped the other side's marks and the two phones
        // showed different debts for the same data (2026-11-16, «Семейный»:
        // −1 541 ₽ on one phone, +43 622 ₽ on the other).
        //
        // Peer visible → owner of the peer's account (via
        // `personalAccountsByUser`). Peer hidden, or its account unknown →
        // the leg's creator: the RPC writes all three legs as the paying user.
        //
        // Same rule as the server's `get_account_settlement` (M10): the peer
        // must sit on ANOTHER account and its owner must be a MEMBER of this
        // one; among several such peers the newest (`created_at` desc, then
        // id) wins. The owner of any visible card used to be credited — a
        // card shared with me by someone outside «Семейный» took A's
        // contribution offline.
        let members = Set(memberUserIds)
        let legsByTransferGroup = Dictionary(
            grouping: transactions.filter { $0.transferGroupId != nil },
            by: { $0.transferGroupId ?? "" }
        )
        func memberOwner(of accountId: String) -> String? {
            personalAccountsByUser.first { user, accounts in
                members.contains(user) && accounts.contains(accountId)
            }?.key
        }
        func payer(of leg: Transaction) -> String {
            guard let groupId = leg.transferGroupId else { return leg.userId }
            let peers = (legsByTransferGroup[groupId] ?? [])
                .filter { $0.id != leg.id && $0.accountId != nil && $0.accountId != sharedAccountId }
                .sorted { a, b in
                    let ca = a.createdAt ?? "", cb = b.createdAt ?? ""
                    return ca != cb ? ca > cb : a.id < b.id
                }
            for peer in peers {
                if let accountId = peer.accountId, let owner = memberOwner(of: accountId) {
                    return owner
                }
            }
            return leg.userId
        }

        for row in autoTransferLegsOnShared {
            let attributedUser = payer(of: row)

            // `row` is a leg ON the shared account (`accountRows`), so its
            // `amountNative` is in the shared account's currency already —
            // the source leg on the payer's personal card is never summed
            // (it only identifies the payer). No FX, no label (M11).
            if row.type == .income {
                contributions[attributedUser, default: 0] += row.amountNative // allowlisted-amount: leg on the shared account, its currency
            } else if row.type == .expense {
                contributions[attributedUser, default: 0] -= row.amountNative // allowlisted-amount: leg on the shared account, its currency
            }
        }

        // 4. Apply past settlements — each closed debt adjusts both sides'
        //    contributions so the greedy pass doesn't re-suggest them.
        //    Only settlements whose period-end falls inside the current
        //    view's period are applied (different periods are independent).
        let periodDateFormatter = AppDateFormatters.utcDate

        for settlement in pastSettlements {
            guard settlement.sharedAccountId == sharedAccountId else { continue }
            guard let endDate = periodDateFormatter.date(from: settlement.periodEnd),
                  period.contains(endDate) else { continue }
            contributions[settlement.fromUserId, default: 0] += settlement.amount
            contributions[settlement.toUserId, default: 0] -= settlement.amount
        }

        // 4b. Apply per-member, per-transaction settlements — each row
        //     means "the share of `transaction_id` that `settled_for_user_id`
        //     owed the payer is resolved off-book". Effect on the math:
        //     credit the settled member by their share (as if they
        //     contributed that amount) and debit the payer by the same
        //     (as if the payer received that amount back). When every
        //     non-payer member of a txn settles, the txn's net delta
        //     becomes zero — same as if it had been split off-app.
        if !transactionMemberSettlements.isEmpty && sumWeights > 0 {
            // Index expense rows by id once; lookups inside the loop are O(1).
            let expensesById = Dictionary(
                uniqueKeysWithValues: autoTransferExpenses.map { ($0.id, $0) }
            )
            // Map auto_transfer_group_id → payer user id via the same
            // `payer(of:)` the contributions walk used, so the payer here is
            // always the member who got the contribution credit — including
            // when RLS hides the peer leg.
            var payerByGroupId: [String: String] = [:]
            for leg in autoTransferLegsOnShared where leg.type == .income {
                guard let groupId = leg.autoTransferGroupId else { continue }
                payerByGroupId[groupId] = payer(of: leg)
            }

            for memberSettlement in transactionMemberSettlements
            where memberSettlement.sharedAccountId == sharedAccountId {
                guard let expense = expensesById[memberSettlement.transactionId] else { continue }
                guard let groupId = expense.autoTransferGroupId,
                      let payer = payerByGroupId[groupId] else { continue }
                // No-op if the payer marks their own share — they don't
                // owe themselves anything for this txn.
                if payer == memberSettlement.settledForUserId { continue }

                // Share for the settled member, in the shared account's
                // currency (the expense row lives on it — no FX, M11).
                let weight = resolvedWeights[memberSettlement.settledForUserId] ?? 1.0
                let share = Decimal(expense.amountNative) * weight / sumWeights // allowlisted-amount: expense on the shared account, its currency
                var rounded = Decimal()
                var src = share
                NSDecimalRound(&rounded, &src, 0, .plain)
                let shareInt = Int64(truncating: rounded as NSDecimalNumber)

                contributions[memberSettlement.settledForUserId, default: 0] += shareInt
                contributions[payer, default: 0] -= shareInt
            }
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
                fairShare: fairShares[uid] ?? 0
            )
        }
    }

    /// Imbalances at or below this magnitude (kopecks) are treated as
    /// settled — no suggestion, member reads "в расчёте". Live-rate FX
    /// normalization rounds every cross-currency leg to the kopeck, so over
    /// dozens of transactions a few tens of kopecks of drift accumulate; a
    /// settle recorded as a whole number then leaves a sub-ruble residual
    /// that resurfaces as a phantom "0,xx ₽ должен" the next recompute.
    /// Nobody transfers 40 kopecks, so we floor it. 1 RUB comfortably covers
    /// the rounding drift while staying below any real debt worth settling.
    static let settlementEpsilon: Int64 = 100  // 1 RUB

    /// Greedy min-cash-flow settlement. O(N log N) where N = member count.
    /// Result size is at most N-1 suggestions — good enough for the MVP
    /// (equal-split only).
    static func settlements(from balances: [MemberBalance]) -> [SettlementSuggestion] {
        // Ignore members whose delta is within the rounding-noise floor —
        // both sides drop out so the greedy pass never proposes a kopeck
        // transfer. Keep mutable copies for the greedy pass.
        var creditors = balances.filter { $0.delta >= settlementEpsilon }
            .sorted { $0.delta > $1.delta }
            .map { (userId: $0.userId, amount: $0.delta) }
        var debtors = balances.filter { $0.delta <= -settlementEpsilon }
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
