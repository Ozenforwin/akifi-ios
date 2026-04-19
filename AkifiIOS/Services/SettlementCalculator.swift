import Foundation

/// Pure, stateless functions that compute who-owes-whom for a shared
/// account over a period. Two-step contract:
///   1. `compute(...)` → per-member balances (contributed, fair share, delta)
///   2. `settlements(from:)` → greedy minimum-cash-flow suggestions
///
/// All amounts are signed Int64 kopecks (minor units). The function
/// contracts don't depend on any UI or Supabase code — trivially testable.
enum SettlementCalculator {

    /// Aggregate of what a single member put into the shared account and
    /// what their fair share was for the period.
    struct MemberBalance: Sendable, Identifiable, Equatable {
        let userId: String
        /// Net contributions to the shared account via auto-transfers from
        /// this user's personal accounts. `transfer-in` minus `transfer-out`.
        let contributed: Int64
        /// `totalExpenses / memberCount` (equal-split). Same for all members.
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
    static func compute(
        sharedAccountId: String,
        transactions: [Transaction],
        memberUserIds: [String],
        personalAccountsByUser: [String: Set<String>],
        period: DateInterval
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
        let accountRows = transactions.filter {
            $0.accountId == sharedAccountId && inPeriod($0.rawDateTime.isEmpty ? $0.date : $0.rawDateTime)
        }

        // 2. Total shared-account expenses (exclude transfer legs).
        let expenses = accountRows.filter {
            $0.type == .expense && $0.transferGroupId == nil
        }
        let totalExpenses: Int64 = expenses.reduce(0) { $0 + $1.amount }
        let memberCount = Int64(memberUserIds.count)
        let fairShare = memberCount > 0 ? totalExpenses / memberCount : 0

        // 3. Build contribution per user by walking auto-transfer groups.
        //    For a group that has an income-leg on sharedAccountId:
        //      - find the sibling expense-leg on any account
        //      - if that account belongs to user U's personal set → credit U
        //    For a group that has an expense-leg on sharedAccountId (rare —
        //    means someone used the shared account to fund a personal
        //    account): debit the receiving user.
        var contributions: [String: Int64] = Dictionary(uniqueKeysWithValues: memberUserIds.map { ($0, 0) })

        let groupedByAutoId = Dictionary(grouping: accountRows.filter { $0.autoTransferGroupId != nil }, by: { $0.autoTransferGroupId! })

        for (groupId, rowsOnShared) in groupedByAutoId {
            // All legs of the group (including ones on other accounts).
            let allLegs = transactions.filter { $0.autoTransferGroupId == groupId && $0.transferGroupId != nil }

            for row in rowsOnShared where row.transferGroupId != nil {
                // peer leg: same group, different account
                guard let peer = allLegs.first(where: { $0.accountId != sharedAccountId }) else {
                    // Peer is invisible (RLS hid it). Best-effort: use the
                    // row's own `user_id` as the contributor.
                    let uid = row.userId
                    if row.type == .income {
                        contributions[uid, default: 0] += row.amount
                    } else if row.type == .expense {
                        contributions[uid, default: 0] -= row.amount
                    }
                    continue
                }
                // Attribute to whichever user owns the peer account.
                let peerAccountId = peer.accountId ?? ""
                let attributedUser: String? = personalAccountsByUser.first { _, accounts in
                    accounts.contains(peerAccountId)
                }?.key ?? row.userId // fall back to the creator if we can't map the peer

                guard let uid = attributedUser else { continue }
                if row.type == .income {
                    contributions[uid, default: 0] += row.amount
                } else if row.type == .expense {
                    contributions[uid, default: 0] -= row.amount
                }
            }
        }

        return memberUserIds.map { uid in
            MemberBalance(
                userId: uid,
                contributed: contributions[uid] ?? 0,
                fairShare: fairShare
            )
        }
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
