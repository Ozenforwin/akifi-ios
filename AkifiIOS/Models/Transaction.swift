import Foundation

struct Transaction: Codable, Identifiable, Sendable {
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
        case type = "tx_type"
        case date
        case merchantName = "merchant"
        case merchantFuzzy = "merchant_fuzzy"
        case transferGroupId = "transfer_group_id"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum TransactionType: String, Codable, Sendable {
    case income
    case expense
    case transfer
}
