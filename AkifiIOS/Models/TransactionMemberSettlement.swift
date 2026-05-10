import Foundation

/// Per-member, per-transaction settlement mark. A row means: "the share of
/// this transaction that `settledForUserId` owed the payer is resolved
/// off-book — exclude it from the running shared-account imbalance."
///
/// Mirrors the `transaction_member_settlements` table. RLS scopes
/// reads/writes to members of the shared account; only the marker
/// (`settledByUserId`) can delete.
struct TransactionMemberSettlement: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let transactionId: String
    let sharedAccountId: String
    let settledForUserId: String
    let settledByUserId: String
    let settledAt: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case transactionId = "transaction_id"
        case sharedAccountId = "shared_account_id"
        case settledForUserId = "settled_for_user_id"
        case settledByUserId = "settled_by_user_id"
        case settledAt = "settled_at"
        case note
    }
}

/// Insert payload — server fills id/settled_at, RLS verifies `settled_by_user_id`
/// matches `auth.uid()`.
struct CreateTransactionMemberSettlementInput: Encodable, Sendable {
    let transaction_id: String
    let shared_account_id: String
    let settled_for_user_id: String
    let settled_by_user_id: String
    let note: String?
}
