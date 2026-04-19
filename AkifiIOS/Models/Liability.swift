import Foundation

/// A user debt — mortgage, loan, credit-card revolving balance, personal
/// debt. Mirrors the `liabilities` table. `currentBalance` is the remaining
/// principal; `originalAmount` and `interestRate` are optional metadata
/// surfaced in the UI for amortization context.
///
/// `currentBalance` / `originalAmount` / `monthlyPayment` are minor units
/// (kopecks). DB columns are BIGINT, pre-multiplied — **no ×100 scaling on
/// decode**. Follow `Settlement.amount`'s convention (not `SavingsGoal`).
///
/// `interestRate` is a NUMERIC(5,3) percentage (e.g. 7.500 for a 7.5% APR).
/// PostgREST serializes NUMERIC either as JSON string (for precision) or
/// as a JSON number depending on version — we accept both.
struct Liability: Codable, Sendable, Identifiable {
    let id: String
    let userId: String
    var name: String
    var category: LiabilityCategory
    /// Minor units (kopecks).
    var currentBalance: Int64
    /// Minor units (kopecks). Optional historical reference.
    var originalAmount: Int64?
    /// APR percentage (e.g. 7.5 for 7.5%). Optional.
    var interestRate: Double?
    var currency: String
    var icon: String?
    var color: String?
    var notes: String?
    /// Minor units (kopecks). Optional.
    var monthlyPayment: Int64?
    /// "yyyy-MM-dd" or nil.
    var endDate: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, category, currency, icon, color, notes
        case currentBalance = "current_balance"
        case originalAmount = "original_amount"
        case interestRate = "interest_rate"
        case monthlyPayment = "monthly_payment"
        case endDate = "end_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, name: String, category: LiabilityCategory,
         currentBalance: Int64, originalAmount: Int64? = nil,
         interestRate: Double? = nil, currency: String, icon: String? = nil,
         color: String? = nil, notes: String? = nil,
         monthlyPayment: Int64? = nil, endDate: String? = nil,
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.userId = userId
        self.name = name
        self.category = category
        self.currentBalance = currentBalance
        self.originalAmount = originalAmount
        self.interestRate = interestRate
        self.currency = currency
        self.icon = icon
        self.color = color
        self.notes = notes
        self.monthlyPayment = monthlyPayment
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(LiabilityCategory.self, forKey: .category)

        // BIGINT in DB — decode as Int64 (PostgREST may serialize as string).
        if let i = try? c.decode(Int64.self, forKey: .currentBalance) {
            currentBalance = i
        } else if let s = try? c.decode(String.self, forKey: .currentBalance), let v = Int64(s) {
            currentBalance = v
        } else {
            currentBalance = 0
        }

        // Optional BIGINTs. `try?` + `.decodeIfPresent` produces `Int64??` —
        // use local helper to flatten both to `Int64?`.
        originalAmount = Self.decodeOptionalBigInt(c, key: .originalAmount)
        monthlyPayment = Self.decodeOptionalBigInt(c, key: .monthlyPayment)

        // NUMERIC(5,3) — may be serialized as string or number.
        if let stringValue = (try? c.decodeIfPresent(String.self, forKey: .interestRate)) ?? nil,
           let d = Double(stringValue) {
            interestRate = d
        } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .interestRate)) ?? nil {
            interestRate = d
        } else {
            interestRate = nil
        }

        currency = try c.decode(String.self, forKey: .currency)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(name, forKey: .name)
        try c.encode(category, forKey: .category)
        try c.encode(currentBalance, forKey: .currentBalance)
        try c.encodeIfPresent(originalAmount, forKey: .originalAmount)
        try c.encodeIfPresent(interestRate, forKey: .interestRate)
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(monthlyPayment, forKey: .monthlyPayment)
        try c.encodeIfPresent(endDate, forKey: .endDate)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    var currencyCode: CurrencyCode {
        CurrencyCode(rawValue: currency.uppercased()) ?? .rub
    }

    /// Small helper because PostgREST may send BIGINT either as a JSON
    /// number or a JSON string. `try?` + `decodeIfPresent` naturally
    /// produces `T??` — we flatten both optionals to `T?` here.
    private static func decodeOptionalBigInt(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int64? {
        if let i = (try? c.decodeIfPresent(Int64.self, forKey: key)) ?? nil {
            return i
        }
        if let s = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil {
            return Int64(s)
        }
        return nil
    }
}

/// Raw values are the DB enum strings (CHECK constraint on `liabilities.category`).
enum LiabilityCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case mortgage
    case loan
    case creditCard = "credit_card"
    case personalDebt = "personal_debt"
    case other

    /// SF Symbol for list/form chrome.
    var symbol: String {
        switch self {
        case .mortgage:     return "house.lodge.fill"
        case .loan:         return "building.columns.fill"
        case .creditCard:   return "creditcard.fill"
        case .personalDebt: return "person.2.fill"
        case .other:        return "doc.text.fill"
        }
    }

    /// Default hex color per category — used when the user hasn't picked one.
    /// All lean red/orange to emphasize "this is money you owe".
    var defaultHex: String {
        switch self {
        case .mortgage:     return "#EF4444"
        case .loan:         return "#F87171"
        case .creditCard:   return "#FB923C"
        case .personalDebt: return "#F59E0B"
        case .other:        return "#94A3B8"
        }
    }

    /// Localized user-facing title (RU/EN/ES via xcstrings).
    var localizedTitle: String {
        switch self {
        case .mortgage:     return String(localized: "liability.category.mortgage")
        case .loan:         return String(localized: "liability.category.loan")
        case .creditCard:   return String(localized: "liability.category.creditCard")
        case .personalDebt: return String(localized: "liability.category.personalDebt")
        case .other:        return String(localized: "liability.category.other")
        }
    }
}
