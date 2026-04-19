import Foundation

/// A fixed-rate deposit (or investment) — 1:1 with an Account of
/// `account_type = 'deposit'`. Mirrors `deposits` table (migration
/// `20260419160100_deposits.sql`).
///
/// Immutability contract:
/// - `interestRate` is **immutable** after creation. If the user wants a
///   new rate, create a new deposit and early-close the old one.
/// - `compoundFrequency` / `startDate` / `endDate` are also logically
///   immutable (UI disallows editing; DB doesn't enforce).
///
/// Balance model:
/// - The Account tied to this deposit carries the principal (sum of
///   contribution transactions).
/// - Accrued interest is computed **live** in the UI via
///   `InterestCalculator.accrueInterest` — not persisted day-by-day.
/// - At maturity / early-close, a single interest-income transaction is
///   created + funds transfer back to `returnToAccountId`.
struct Deposit: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let userId: String
    let accountId: String
    /// Annual rate in percent, e.g. 12.5 means 12.5% APR. Immutable.
    var interestRate: Decimal
    var compoundFrequency: CompoundFrequency
    /// "yyyy-MM-dd" — lot-based accrual pivot for the first contribution.
    var startDate: String
    /// "yyyy-MM-dd" or nil for open-ended deposits.
    var endDate: String?
    /// Reserved for Phase 2 — always 0 in MVP.
    var earlyClosePenaltyRate: Decimal
    var status: DepositStatus
    var closedAt: String?
    var returnToAccountId: String?
    var notes: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case accountId = "account_id"
        case interestRate = "interest_rate"
        case compoundFrequency = "compound_frequency"
        case startDate = "start_date"
        case endDate = "end_date"
        case earlyClosePenaltyRate = "early_close_penalty_rate"
        case status
        case closedAt = "closed_at"
        case returnToAccountId = "return_to_account_id"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String,
         userId: String,
         accountId: String,
         interestRate: Decimal,
         compoundFrequency: CompoundFrequency,
         startDate: String,
         endDate: String? = nil,
         earlyClosePenaltyRate: Decimal = 0,
         status: DepositStatus = .active,
         closedAt: String? = nil,
         returnToAccountId: String? = nil,
         notes: String? = nil,
         createdAt: String? = nil,
         updatedAt: String? = nil) {
        self.id = id
        self.userId = userId
        self.accountId = accountId
        self.interestRate = interestRate
        self.compoundFrequency = compoundFrequency
        self.startDate = startDate
        self.endDate = endDate
        self.earlyClosePenaltyRate = earlyClosePenaltyRate
        self.status = status
        self.closedAt = closedAt
        self.returnToAccountId = returnToAccountId
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        accountId = try c.decode(String.self, forKey: .accountId)
        interestRate = Self.decodeDecimal(c, key: .interestRate) ?? 0
        compoundFrequency = try c.decode(CompoundFrequency.self, forKey: .compoundFrequency)
        startDate = try c.decode(String.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        earlyClosePenaltyRate = Self.decodeDecimal(c, key: .earlyClosePenaltyRate) ?? 0
        status = try c.decodeIfPresent(DepositStatus.self, forKey: .status) ?? .active
        closedAt = try c.decodeIfPresent(String.self, forKey: .closedAt)
        returnToAccountId = try c.decodeIfPresent(String.self, forKey: .returnToAccountId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(interestRate, forKey: .interestRate)
        try c.encode(compoundFrequency, forKey: .compoundFrequency)
        try c.encode(startDate, forKey: .startDate)
        try c.encodeIfPresent(endDate, forKey: .endDate)
        try c.encode(earlyClosePenaltyRate, forKey: .earlyClosePenaltyRate)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
        try c.encodeIfPresent(returnToAccountId, forKey: .returnToAccountId)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    /// NUMERIC(6,3) columns come back as JSON string (precision) or number.
    /// Accept both to keep the decoder robust across PostgREST versions.
    private static func decodeDecimal(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Decimal? {
        if let s = try? c.decode(String.self, forKey: key), let d = Decimal(string: s) {
            return d
        }
        if let dbl = try? c.decode(Double.self, forKey: key) {
            return Decimal(dbl)
        }
        return nil
    }
}

/// Compounding schedule. Determines `n` in `A = P(1 + r/n)^(nt)`. Raw values
/// match the DB CHECK constraint on `deposits.compound_frequency`.
enum CompoundFrequency: String, Codable, Sendable, CaseIterable, Hashable {
    case simple
    case daily
    case monthly
    case quarterly
    case yearly

    /// Periods per year — drives the compound formula.
    /// `simple` is a degenerate case (no capitalization) and returns 1 so
    /// call sites can multiply safely; the formula itself branches on `.simple`.
    var periodsPerYear: Decimal {
        switch self {
        case .simple:    return 1
        case .daily:     return 365
        case .monthly:   return 12
        case .quarterly: return 4
        case .yearly:    return 1
        }
    }

    var localizedTitle: String {
        switch self {
        case .simple:    return String(localized: "deposit.frequency.simple")
        case .daily:     return String(localized: "deposit.frequency.daily")
        case .monthly:   return String(localized: "deposit.frequency.monthly")
        case .quarterly: return String(localized: "deposit.frequency.quarterly")
        case .yearly:    return String(localized: "deposit.frequency.yearly")
        }
    }
}

enum DepositStatus: String, Codable, Sendable, Hashable {
    case active
    case matured
    case closedEarly = "closed_early"

    var localizedTitle: String {
        switch self {
        case .active:      return String(localized: "deposit.status.active")
        case .matured:     return String(localized: "deposit.status.matured")
        case .closedEarly: return String(localized: "deposit.status.closedEarly")
        }
    }
}
