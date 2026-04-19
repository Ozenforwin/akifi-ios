import Foundation

/// Point-in-time capture of `net_worth = accounts + assets - liabilities`
/// stored in the user's base currency. Rows are UNIQUE on (user_id,
/// snapshot_date) — at most one per day, upserted when the dashboard loads.
///
/// All monetary fields are minor units (kopecks) stored as BIGINT in the DB.
/// PostgREST may serialize BIGINT as a JSON string for precision — the
/// decoder handles both string and number forms.
struct NetWorthSnapshot: Codable, Sendable, Identifiable {
    let id: String
    let userId: String
    /// "yyyy-MM-dd"
    let snapshotDate: String
    let accountsTotal: Int64
    let assetsTotal: Int64
    let liabilitiesTotal: Int64
    let netWorth: Int64
    let currency: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case snapshotDate = "snapshot_date"
        case accountsTotal = "accounts_total"
        case assetsTotal = "assets_total"
        case liabilitiesTotal = "liabilities_total"
        case netWorth = "net_worth"
        case currency
        case createdAt = "created_at"
    }

    init(id: String, userId: String, snapshotDate: String, accountsTotal: Int64,
         assetsTotal: Int64, liabilitiesTotal: Int64, netWorth: Int64,
         currency: String, createdAt: String? = nil) {
        self.id = id
        self.userId = userId
        self.snapshotDate = snapshotDate
        self.accountsTotal = accountsTotal
        self.assetsTotal = assetsTotal
        self.liabilitiesTotal = liabilitiesTotal
        self.netWorth = netWorth
        self.currency = currency
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        snapshotDate = try c.decode(String.self, forKey: .snapshotDate)

        func decodeBigInt(_ key: CodingKeys) -> Int64 {
            if let i = try? c.decode(Int64.self, forKey: key) { return i }
            if let s = try? c.decode(String.self, forKey: key), let v = Int64(s) { return v }
            return 0
        }

        accountsTotal = decodeBigInt(.accountsTotal)
        assetsTotal = decodeBigInt(.assetsTotal)
        liabilitiesTotal = decodeBigInt(.liabilitiesTotal)
        netWorth = decodeBigInt(.netWorth)

        currency = try c.decode(String.self, forKey: .currency)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}
