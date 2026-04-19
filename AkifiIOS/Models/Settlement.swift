import Foundation

/// A recorded "who owes whom" reconciliation for a shared account over a
/// specific period. Created when a user taps "Mark as settled" on a
/// `SettlementSuggestion`. Optionally linked to a real transfer between
/// personal accounts via `linkedTransferGroupId`.
///
/// Mirrors the `settlements` table. `amount` is stored in minor units
/// (kopecks) on the client; the DB column is BIGINT.
struct Settlement: Codable, Sendable, Identifiable {
    let id: String
    let sharedAccountId: String
    let fromUserId: String
    let toUserId: String
    /// Minor units (kopecks). Always positive — direction lives in from/to.
    var amount: Int64
    var currency: String
    /// "yyyy-MM-dd"
    var periodStart: String
    /// "yyyy-MM-dd"
    var periodEnd: String
    /// ISO timestamp of when the record was created.
    let settledAt: String?
    let settledBy: String
    var linkedTransferGroupId: String?
    var note: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sharedAccountId = "shared_account_id"
        case fromUserId = "from_user_id"
        case toUserId = "to_user_id"
        case amount, currency
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case settledAt = "settled_at"
        case settledBy = "settled_by"
        case linkedTransferGroupId = "linked_transfer_group_id"
        case note
        case createdAt = "created_at"
    }

    init(id: String, sharedAccountId: String, fromUserId: String, toUserId: String,
         amount: Int64, currency: String, periodStart: String, periodEnd: String,
         settledAt: String? = nil, settledBy: String, linkedTransferGroupId: String? = nil,
         note: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.sharedAccountId = sharedAccountId
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.amount = amount
        self.currency = currency
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.settledAt = settledAt
        self.settledBy = settledBy
        self.linkedTransferGroupId = linkedTransferGroupId
        self.note = note
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sharedAccountId = try c.decode(String.self, forKey: .sharedAccountId)
        fromUserId = try c.decode(String.self, forKey: .fromUserId)
        toUserId = try c.decode(String.self, forKey: .toUserId)
        // `amount` in DB is BIGINT in minor units (kopecks) — no ×100 scaling.
        if let i = try? c.decode(Int64.self, forKey: .amount) {
            amount = i
        } else if let s = try? c.decode(String.self, forKey: .amount), let v = Int64(s) {
            amount = v
        } else {
            amount = 0
        }
        currency = try c.decode(String.self, forKey: .currency)
        periodStart = try c.decode(String.self, forKey: .periodStart)
        periodEnd = try c.decode(String.self, forKey: .periodEnd)
        settledAt = try c.decodeIfPresent(String.self, forKey: .settledAt)
        settledBy = try c.decode(String.self, forKey: .settledBy)
        linkedTransferGroupId = try c.decodeIfPresent(String.self, forKey: .linkedTransferGroupId)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sharedAccountId, forKey: .sharedAccountId)
        try c.encode(fromUserId, forKey: .fromUserId)
        try c.encode(toUserId, forKey: .toUserId)
        try c.encode(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(periodStart, forKey: .periodStart)
        try c.encode(periodEnd, forKey: .periodEnd)
        try c.encodeIfPresent(settledAt, forKey: .settledAt)
        try c.encode(settledBy, forKey: .settledBy)
        try c.encodeIfPresent(linkedTransferGroupId, forKey: .linkedTransferGroupId)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}
