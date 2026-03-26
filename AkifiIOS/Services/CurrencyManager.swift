import Foundation

@Observable @MainActor
final class CurrencyManager {
    var selectedCurrency: CurrencyCode = .usd
    var rates: [String: Double] = [:]

    private let supabase = SupabaseManager.shared.client

    func format(_ amountInBase: Decimal) -> String {
        let rate = Decimal(rates[selectedCurrency.rawValue] ?? 1.0)
        let converted = amountInBase * rate

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = selectedCurrency.rawValue
        formatter.maximumFractionDigits = 2

        return formatter.string(from: converted as NSDecimalNumber) ?? "0"
    }

    func formatAmount(_ amount: Decimal) -> String {
        let absAmount = abs(amount)
        let rate = Decimal(rates[selectedCurrency.rawValue] ?? 1.0)
        let converted = absAmount * rate

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2

        let symbol = selectedCurrency.symbol
        let formatted = formatter.string(from: converted as NSDecimalNumber) ?? "0"
        return "\(symbol)\(formatted)"
    }

    func fetchRates() async {
        // TODO: Implement exchange rate fetching
        rates = ["USD": 1.0, "RUB": 90.0, "EUR": 0.92]
    }
}

enum CurrencyCode: String, CaseIterable, Codable, Sendable {
    case usd = "USD"
    case rub = "RUB"
    case eur = "EUR"
    case gbp = "GBP"
    case cny = "CNY"
    case jpy = "JPY"

    var symbol: String {
        switch self {
        case .usd: return "$"
        case .rub: return "₽"
        case .eur: return "€"
        case .gbp: return "£"
        case .cny: return "¥"
        case .jpy: return "¥"
        }
    }

    var name: String {
        switch self {
        case .usd: return "US Dollar"
        case .rub: return "Российский рубль"
        case .eur: return "Euro"
        case .gbp: return "British Pound"
        case .cny: return "Chinese Yuan"
        case .jpy: return "Japanese Yen"
        }
    }
}
