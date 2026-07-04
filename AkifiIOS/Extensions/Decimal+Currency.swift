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

extension Decimal {
    /// Main units → kopecks (×100, plain rounding). Counterpart of
    /// `Int64.displayAmount`; used when a DTO Decimal has to land in a
    /// local `Transaction.amountNative` without a server round-trip.
    var kopecks: Int64 {
        var scaled = self * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }
}
