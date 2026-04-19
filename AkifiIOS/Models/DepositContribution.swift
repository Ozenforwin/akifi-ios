import Foundation

/// One lot in a deposit's contribution history. Stored in
/// `deposit_contributions` (migration `20260419160200_deposit_contributions.sql`).
///
/// Lot-based accrual: each contribution has its own `contributedAt` start
/// date. `InterestCalculator` computes interest per-lot and sums, which
/// eliminates the underestimate that a naive aggregate-principal scheme
/// would introduce for multi-contribution deposits.
///
/// Cross-currency: when a contribution is sourced from an account in a
/// different currency, we persist the original `sourceAmount` /
/// `sourceCurrency` + the FX `fxRate` snapshot — so the history is
/// faithful regardless of future rate changes. `amount` is always in the
/// deposit's own currency (kopecks).
struct DepositContribution: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let depositId: String
    let userId: String
    /// Kopecks in the deposit's currency.
    var amount: Int64
    /// "yyyy-MM-dd"
    var contributedAt: String
    var sourceAccountId: String?
    var sourceCurrency: String?
    /// Kopecks in `sourceCurrency`, present only for cross-currency rows.
    var sourceAmount: Int64?
    var fxRate: Decimal?
    var transferGroupId: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case depositId = "deposit_id"
        case userId = "user_id"
        case amount
        case contributedAt = "contributed_at"
        case sourceAccountId = "source_account_id"
        case sourceCurrency = "source_currency"
        case sourceAmount = "source_amount"
        case fxRate = "fx_rate"
        case transferGroupId = "transfer_group_id"
        case createdAt = "created_at"
    }

    init(id: String,
         depositId: String,
         userId: String,
         amount: Int64,
         contributedAt: String,
         sourceAccountId: String? = nil,
         sourceCurrency: String? = nil,
         sourceAmount: Int64? = nil,
         fxRate: Decimal? = nil,
         transferGroupId: String? = nil,
         createdAt: String? = nil) {
        self.id = id
        self.depositId = depositId
        self.userId = userId
        self.amount = amount
        self.contributedAt = contributedAt
        self.sourceAccountId = sourceAccountId
        self.sourceCurrency = sourceCurrency
        self.sourceAmount = sourceAmount
        self.fxRate = fxRate
        self.transferGroupId = transferGroupId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        depositId = try c.decode(String.self, forKey: .depositId)
        userId = try c.decode(String.self, forKey: .userId)
        amount = Self.decodeBigInt(c, key: .amount) ?? 0
        contributedAt = try c.decode(String.self, forKey: .contributedAt)
        sourceAccountId = try c.decodeIfPresent(String.self, forKey: .sourceAccountId)
        sourceCurrency = try c.decodeIfPresent(String.self, forKey: .sourceCurrency)
        sourceAmount = Self.decodeBigInt(c, key: .sourceAmount)
        fxRate = Self.decodeDecimal(c, key: .fxRate)
        transferGroupId = try c.decodeIfPresent(String.self, forKey: .transferGroupId)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(depositId, forKey: .depositId)
        try c.encode(userId, forKey: .userId)
        try c.encode(amount, forKey: .amount)
        try c.encode(contributedAt, forKey: .contributedAt)
        try c.encodeIfPresent(sourceAccountId, forKey: .sourceAccountId)
        try c.encodeIfPresent(sourceCurrency, forKey: .sourceCurrency)
        try c.encodeIfPresent(sourceAmount, forKey: .sourceAmount)
        try c.encodeIfPresent(fxRate, forKey: .fxRate)
        try c.encodeIfPresent(transferGroupId, forKey: .transferGroupId)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    private static func decodeBigInt(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int64? {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let v = Int64(s) { return v }
        return nil
    }

    private static func decodeDecimal(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Decimal? {
        if let s = try? c.decode(String.self, forKey: key), let d = Decimal(string: s) { return d }
        if let dbl = try? c.decode(Double.self, forKey: key) { return Decimal(dbl) }
        return nil
    }
}
