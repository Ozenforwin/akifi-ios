import Foundation

struct Category: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var accountId: String?
    var name: String
    var icon: String
    var color: String
    var type: CategoryType
    var isActive: Bool
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case accountId = "account_id"
        case name, icon, color, type
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

enum CategoryType: String, Codable, Sendable {
    case income
    case expense
}
