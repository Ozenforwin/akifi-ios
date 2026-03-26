import Foundation

struct Account: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let userId: String
    var name: String
    var icon: String
    var color: String
    var initialBalance: Int64
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, icon, color
        case initialBalance = "initial_balance"
        case createdAt = "created_at"
    }
}

struct AccountMember: Codable, Identifiable, Sendable {
    let id: String
    let accountId: String
    let userId: String
    var role: AccountRole
    let invitedBy: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case userId = "user_id"
        case role
        case invitedBy = "invited_by"
        case createdAt = "created_at"
    }
}

enum AccountRole: String, Codable, Sendable {
    case owner
    case editor
    case viewer
}
