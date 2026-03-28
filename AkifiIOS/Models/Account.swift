import Foundation

struct Account: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let userId: String
    var name: String
    var icon: String
    var color: String
    var initialBalance: Int64
    var isPrimary: Bool
    var currency: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, icon, color, currency
        case initialBalance = "initial_balance"
        case isPrimary = "is_primary"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decode(String.self, forKey: .color)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "rub"
        // DB stores initial_balance as bigint in whole rubles — convert to kopecks
        let rawBalance = try container.decode(Int64.self, forKey: .initialBalance)
        initialBalance = rawBalance * 100
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }

    init(id: String, userId: String, name: String, icon: String, color: String, initialBalance: Int64, isPrimary: Bool = false, currency: String = "rub", createdAt: String? = nil) {
        self.id = id; self.userId = userId; self.name = name; self.icon = icon
        self.color = color; self.initialBalance = initialBalance; self.isPrimary = isPrimary
        self.currency = currency; self.createdAt = createdAt
    }

    var currencyCode: CurrencyCode {
        CurrencyCode(rawValue: currency.uppercased()) ?? .rub
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
