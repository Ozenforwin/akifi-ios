import Foundation

struct ReceiptScan: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var fileId: String?
    var status: String
    var recognizedItems: [String: AnyCodable]?
    var totalAmount: Int64?
    var currency: String?
    var merchant: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case fileId = "file_id"
        case status
        case recognizedItems = "recognized_items"
        case totalAmount = "total_amount"
        case currency, merchant
        case createdAt = "created_at"
    }
}

// Simple type-erased codable wrapper
struct AnyCodable: Codable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = String(num)
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
