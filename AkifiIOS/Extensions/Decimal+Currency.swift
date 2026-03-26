import Foundation

extension Decimal {
    func formatted(currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: self as NSDecimalNumber) ?? "0"
    }
}

extension Int64 {
    /// Convert base amount (stored in minor units) to display Decimal
    var displayAmount: Decimal {
        Decimal(self) / 100
    }
}
