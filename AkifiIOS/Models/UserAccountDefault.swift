import Foundation

/// Per-user default source-account for a target account. When the target
/// is a shared account, we pre-select `defaultSourceId` (a personal account
/// of the same currency) in `TransactionFormView` so recurring "I paid the
/// family groceries from my Tinkoff card" flows become one-tap.
///
/// Mirrors the `user_account_defaults` table. RLS ensures each row is owned
/// by `auth.uid()`.
struct UserAccountDefault: Codable, Sendable, Identifiable {
    let userId: String
    let accountId: String
    var defaultSourceId: String?
    let createdAt: String?
    let updatedAt: String?

    /// Composite identity — the PK is (user_id, account_id).
    var id: String { "\(userId)::\(accountId)" }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accountId = "account_id"
        case defaultSourceId = "default_source_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(userId: String, accountId: String, defaultSourceId: String?, createdAt: String? = nil, updatedAt: String? = nil) {
        self.userId = userId
        self.accountId = accountId
        self.defaultSourceId = defaultSourceId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
