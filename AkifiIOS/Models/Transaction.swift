import Foundation

struct Transaction: Decodable, Identifiable, Sendable {
    let id: String
    let userId: String
    var accountId: String?
    var amount: Int64
    var currency: String?
    var description: String?
    var categoryId: String?
    var type: TransactionType
    var date: String
    var merchantName: String?
    var merchantFuzzy: String?
    var transferGroupId: String?
    var status: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case accountId = "account_id"
        case amount, currency, description
        case categoryId = "category_id"
        case type
        case date
        case merchantName = "merchant_name"
        case merchantFuzzy = "merchant_normalized"
        case transferGroupId = "transfer_group_id"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, accountId: String?, amount: Int64, currency: String?, description: String?, categoryId: String?, type: TransactionType, date: String, merchantName: String?, merchantFuzzy: String?, transferGroupId: String?, status: String?, createdAt: String?, updatedAt: String?) {
        self.id = id; self.userId = userId; self.accountId = accountId; self.amount = amount
        self.currency = currency; self.description = description; self.categoryId = categoryId
        self.type = type; self.date = date; self.merchantName = merchantName
        self.merchantFuzzy = merchantFuzzy; self.transferGroupId = transferGroupId
        self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        amount = Self.decodeAmount(from: container)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        type = try container.decode(TransactionType.self, forKey: .type)
        // Normalize timestamptz "2026-03-26 00:00:00+00" → "2026-03-26"
        let rawDate = try container.decode(String.self, forKey: .date)
        date = String(rawDate.prefix(10))
        merchantName = try container.decodeIfPresent(String.self, forKey: .merchantName)
        merchantFuzzy = try container.decodeIfPresent(String.self, forKey: .merchantFuzzy)
        transferGroupId = try container.decodeIfPresent(String.self, forKey: .transferGroupId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Decode numeric amount from DB (rubles, e.g. 40502.23 or "40502.23") → Int64 kopecks (4050223)
    static func decodeAmount(from container: KeyedDecodingContainer<CodingKeys>) -> Int64 {
        // Try String first — PostgREST sends numeric as string to preserve precision
        if let str = try? container.decode(String.self, forKey: .amount),
           let decimal = Decimal(string: str) {
            let result = Int64(truncating: (decimal * 100) as NSDecimalNumber)
            print("[TX] amount string=\(str) → kopecks=\(result)")
            return result
        }
        // Fallback: JSON number
        if let dbl = try? container.decode(Double.self, forKey: .amount) {
            let result = Int64((dbl * 100).rounded())
            print("[TX] amount double=\(dbl) → kopecks=\(result)")
            return result
        }
        print("[TX] amount: failed to decode")
        return 0
    }
}

enum TransactionType: String, Codable, Sendable {
    case income
    case expense
    case transfer
}

extension Transaction {
    /// True if this is a transfer between accounts (either type==transfer or has transferGroupId)
    var isTransfer: Bool {
        type == .transfer || transferGroupId != nil
    }
}
