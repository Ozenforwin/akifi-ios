import Foundation

/// Membership row for a shared budget — trimmed mirror of `AccountMember`
/// (no split weights: budget progress is a shared number, not a settlement).
/// Backed by `budget_members`; the owner has a row too (role = 'owner').
struct BudgetMember: Codable, Identifiable, Sendable {
    let id: String
    let budgetId: String
    let userId: String
    var role: AccountRole
    let invitedBy: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case budgetId = "budget_id"
        case userId = "user_id"
        case role
        case invitedBy = "invited_by"
        case createdAt = "created_at"
    }

    init(id: String, budgetId: String, userId: String, role: AccountRole, invitedBy: String? = nil, createdAt: String? = nil) {
        self.id = id; self.budgetId = budgetId; self.userId = userId; self.role = role
        self.invitedBy = invitedBy; self.createdAt = createdAt
    }
}
