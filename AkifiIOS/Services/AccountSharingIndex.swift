import Foundation

/// "Is this account shared?" — one rule for every screen (B7).
///
/// "Shared" used to be inferred from "someone else has a transaction on
/// it". A freshly shared account therefore did not count as shared for its
/// owner until the partner wrote something: no «Оплачено с» picker, the
/// owner's expenses were saved without an auto-transfer and never reached
/// the settlement. Membership is the fact; transactions are a side effect.
///
/// The membership data itself lives in `AccountMembershipStore`
/// (`dataStore.accountMembership`, one complete-set read of
/// `account_members` shared by Home, the forms, the carousel, transaction
/// rows and the shared-account screen). This type only holds the decision
/// rule, so the forms and the carousel can't drift from the rest.
enum AccountSharingIndex {

    /// 1. an account owned by someone else is shared with me by definition;
    /// 2. with membership loaded for THIS user, more than one member row;
    /// 3. membership not loaded yet (first frame, offline cold start) → the
    ///    legacy heuristic, so the UI degrades to the old behaviour instead
    ///    of hiding sharing altogether.
    nonisolated static func isShared(
        _ account: Account,
        currentUserId: String?,
        memberCounts: [String: Int]?,
        fallback: () -> Bool
    ) -> Bool {
        if let uid = currentUserId, account.userId != uid { return true }
        if let memberCounts { return (memberCounts[account.id] ?? 0) > 1 }
        return fallback()
    }

    /// The rule applied to the app-wide membership snapshot.
    @MainActor
    static func isShared(_ account: Account, dataStore: DataStore, currentUserId: String?) -> Bool {
        isShared(account,
                 currentUserId: currentUserId,
                 memberCounts: dataStore.accountMembership.memberCounts(viewerId: currentUserId)) {
            hasOtherMembersRows(account, currentUserId: currentUserId, transactions: dataStore.transactions)
        }
    }

    /// The legacy heuristic, used only until membership is loaded.
    static func hasOtherMembersRows(_ account: Account, currentUserId: String?, transactions: [Transaction]) -> Bool {
        guard let uid = currentUserId else { return false }
        return transactions.contains { $0.accountId == account.id && $0.userId != uid }
    }
}
