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
    /// Classifier for checking/savings/cash/deposit/investment. Defaults to
    /// `.checking` on decode when the column is missing (backward compat for
    /// pre-migration cached rows).
    var accountType: AccountType
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, icon, color, currency
        case initialBalance = "initial_balance"
        case isPrimary = "is_primary"
        case accountType = "account_type"
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
        accountType = try container.decodeIfPresent(AccountType.self, forKey: .accountType) ?? .checking
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(color, forKey: .color)
        try container.encode(currency, forKey: .currency)
        // Store back as rubles (same format as DB) so decode always does *100
        try container.encode(initialBalance / 100, forKey: .initialBalance)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(accountType, forKey: .accountType)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    init(id: String, userId: String, name: String, icon: String, color: String, initialBalance: Int64, isPrimary: Bool = false, currency: String = "rub", accountType: AccountType = .checking, createdAt: String? = nil) {
        self.id = id; self.userId = userId; self.name = name; self.icon = icon
        self.color = color; self.initialBalance = initialBalance; self.isPrimary = isPrimary
        self.currency = currency; self.accountType = accountType; self.createdAt = createdAt
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
    /// Relative share for settlement fairShare math. Default 1.0 = equal
    /// split. `SettlementCalculator` normalizes per-account at compute
    /// time: `fairShare(M) = total * weight(M) / sum(weights)`.
    /// NUMERIC(6,3) in DB, backed by `account_members.split_weight`.
    var splitWeight: Decimal

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case userId = "user_id"
        case role
        case invitedBy = "invited_by"
        case createdAt = "created_at"
        case splitWeight = "split_weight"
    }

    init(id: String, accountId: String, userId: String, role: AccountRole, invitedBy: String? = nil, createdAt: String? = nil, splitWeight: Decimal = 1.0) {
        self.id = id; self.accountId = accountId; self.userId = userId; self.role = role
        self.invitedBy = invitedBy; self.createdAt = createdAt
        self.splitWeight = splitWeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountId = try c.decode(String.self, forKey: .accountId)
        userId = try c.decode(String.self, forKey: .userId)
        role = try c.decode(AccountRole.self, forKey: .role)
        invitedBy = try c.decodeIfPresent(String.self, forKey: .invitedBy)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        // PostgREST serializes NUMERIC as a string (to preserve precision)
        // most of the time, but can also emit a JSON number depending on
        // version. Handle both + fall back to 1.0 for pre-migration rows.
        if let str = try? c.decode(String.self, forKey: .splitWeight),
           let d = Decimal(string: str) {
            splitWeight = d
        } else if let dbl = try? c.decode(Double.self, forKey: .splitWeight) {
            splitWeight = Decimal(dbl)
        } else {
            splitWeight = 1.0
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(userId, forKey: .userId)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(invitedBy, forKey: .invitedBy)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(splitWeight, forKey: .splitWeight)
    }
}

enum AccountRole: String, Codable, Sendable {
    case owner
    case editor
    case viewer
}
