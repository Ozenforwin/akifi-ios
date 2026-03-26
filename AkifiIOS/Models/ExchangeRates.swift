import Foundation

struct ExchangeRates: Codable, Sendable {
    let base: String
    let rates: [String: Double]
}
