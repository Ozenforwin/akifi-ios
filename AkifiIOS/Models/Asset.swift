import Foundation

/// A user-owned asset outside of liquid account balances — real estate,
/// vehicles, crypto stashes that don't sit on an exchange account,
/// investment positions, collectibles. Current value is user-maintained;
/// no mark-to-market automation. Mirrors the `assets` table.
///
/// `currentValue` is stored as minor units (kopecks) on the client. The DB
/// column is `BIGINT`, pre-multiplied — **no ×100 scaling on decode**.
/// This matches `Settlement.amount`'s convention; `savings_goals` uses the
/// old NUMERIC + ×100 scheme, don't confuse the two.
struct Asset: Codable, Sendable, Identifiable {
    let id: String
    let userId: String
    var name: String
    var category: AssetCategory
    /// Minor units (kopecks).
    var currentValue: Int64
    var currency: String
    var icon: String?
    var color: String?
    var notes: String?
    /// "yyyy-MM-dd" or nil.
    var acquiredDate: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, category, currency, icon, color, notes
        case currentValue = "current_value"
        case acquiredDate = "acquired_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, name: String, category: AssetCategory,
         currentValue: Int64, currency: String, icon: String? = nil,
         color: String? = nil, notes: String? = nil, acquiredDate: String? = nil,
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.userId = userId
        self.name = name
        self.category = category
        self.currentValue = currentValue
        self.currency = currency
        self.icon = icon
        self.color = color
        self.notes = notes
        self.acquiredDate = acquiredDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(AssetCategory.self, forKey: .category)
        // BIGINT in DB — decode as Int64 (PostgREST may serialize as string).
        if let i = try? c.decode(Int64.self, forKey: .currentValue) {
            currentValue = i
        } else if let s = try? c.decode(String.self, forKey: .currentValue), let v = Int64(s) {
            currentValue = v
        } else {
            currentValue = 0
        }
        currency = try c.decode(String.self, forKey: .currency)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        acquiredDate = try c.decodeIfPresent(String.self, forKey: .acquiredDate)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(name, forKey: .name)
        try c.encode(category, forKey: .category)
        try c.encode(currentValue, forKey: .currentValue)
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(acquiredDate, forKey: .acquiredDate)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    var currencyCode: CurrencyCode {
        CurrencyCode(rawValue: currency.uppercased()) ?? .rub
    }
}

/// Raw values are the DB enum strings (CHECK constraint on `assets.category`).
enum AssetCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case realEstate = "real_estate"
    case vehicle
    case crypto
    case investment
    case collectible
    case cash
    case other

    /// SF Symbol for list/form chrome.
    var symbol: String {
        switch self {
        case .realEstate:  return "house.fill"
        case .vehicle:     return "car.fill"
        case .crypto:      return "bitcoinsign.circle.fill"
        case .investment:  return "chart.line.uptrend.xyaxis"
        case .collectible: return "star.fill"
        case .cash:        return "banknote.fill"
        case .other:       return "square.stack.3d.up.fill"
        }
    }

    /// Default hex color per category — used when the user hasn't picked one.
    var defaultHex: String {
        switch self {
        case .realEstate:  return "#4ADE80"
        case .vehicle:     return "#60A5FA"
        case .crypto:      return "#FBBF24"
        case .investment:  return "#A78BFA"
        case .collectible: return "#F472B6"
        case .cash:        return "#34D399"
        case .other:       return "#94A3B8"
        }
    }

    /// Localized user-facing title (RU/EN/ES via xcstrings).
    var localizedTitle: String {
        switch self {
        case .realEstate:  return String(localized: "asset.category.realEstate")
        case .vehicle:     return String(localized: "asset.category.vehicle")
        case .crypto:      return String(localized: "asset.category.crypto")
        case .investment:  return String(localized: "asset.category.investment")
        case .collectible: return String(localized: "asset.category.collectible")
        case .cash:        return String(localized: "asset.category.cash")
        case .other:       return String(localized: "asset.category.other")
        }
    }
}
