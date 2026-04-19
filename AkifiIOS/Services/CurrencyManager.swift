import Foundation

@Observable @MainActor
final class CurrencyManager {
    var selectedCurrency: CurrencyCode = .rub {
        didSet {
            UserDefaults.standard.set(selectedCurrency.rawValue, forKey: "selected_currency")
            resetFormatters()
        }
    }
    var rates: [String: Double] = [:]

    private let exchangeRateService = ExchangeRateService()

    // Cached formatters — NumberFormatter is expensive to create
    private var currencyFormatter: NumberFormatter
    private var decimalFormatter: NumberFormatter

    init() {
        currencyFormatter = NumberFormatter()
        decimalFormatter = NumberFormatter()

        if let saved = UserDefaults.standard.string(forKey: "selected_currency"),
           let code = CurrencyCode(rawValue: saved) {
            selectedCurrency = code
        }
        if let savedData = UserDefaults.standard.string(forKey: "data_currency"),
           let code = CurrencyCode(rawValue: savedData) {
            dataCurrency = code
        }
        resetFormatters()
    }

    /// The currency that amounts are stored in (user's default currency from profile)
    var dataCurrency: CurrencyCode = .rub {
        didSet {
            UserDefaults.standard.set(dataCurrency.rawValue, forKey: "data_currency")
        }
    }

    private func resetFormatters() {
        currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = selectedCurrency.rawValue
        currencyFormatter.maximumFractionDigits = 2

        decimalFormatter = NumberFormatter()
        decimalFormatter.numberStyle = .decimal
        decimalFormatter.maximumFractionDigits = selectedCurrency.decimals
        decimalFormatter.minimumFractionDigits = selectedCurrency.decimals
    }

    /// Convert amount from data currency to selected display currency
    func convert(_ amount: Decimal) -> Decimal {
        let fromRate = Decimal(rates[dataCurrency.rawValue] ?? 1.0)
        let toRate = Decimal(rates[selectedCurrency.rawValue] ?? 1.0)
        guard fromRate != 0 else { return amount }
        return amount / fromRate * toRate
    }

    /// Convert amount from display currency back to data (base) currency
    func toBase(_ amountInDisplayCurrency: Decimal) -> Decimal {
        let fromRate = Decimal(rates[dataCurrency.rawValue] ?? 1.0)
        let toRate = Decimal(rates[selectedCurrency.rawValue] ?? 1.0)
        guard toRate != 0 else { return amountInDisplayCurrency }
        return amountInDisplayCurrency / toRate * fromRate
    }

    /// Convert amount from base (data) currency to a specific account currency
    func convertToAccountCurrency(_ amountInBase: Decimal, accountCurrency: CurrencyCode) -> Decimal {
        let fromRate = Decimal(rates[dataCurrency.rawValue] ?? 1.0)
        let toRate = Decimal(rates[accountCurrency.rawValue] ?? 1.0)
        guard fromRate != 0 else { return amountInBase }
        return amountInBase / fromRate * toRate
    }

    /// Convert amount from a specific account currency back to base (data) currency
    func convertFromAccountCurrency(_ amount: Decimal, accountCurrency: CurrencyCode) -> Decimal {
        let fromRate = Decimal(rates[dataCurrency.rawValue] ?? 1.0)
        let toRate = Decimal(rates[accountCurrency.rawValue] ?? 1.0)
        guard toRate != 0 else { return amount }
        return amount / toRate * fromRate
    }

    func format(_ amount: Decimal) -> String {
        let converted = convert(amount)
        return currencyFormatter.string(from: converted as NSDecimalNumber) ?? "0"
    }

    func formatAmount(_ amount: Decimal) -> String {
        let absAmount = abs(amount)
        let converted = convert(absAmount)
        let formatted = decimalFormatter.string(from: converted as NSDecimalNumber) ?? "0"
        return "\(formatted) \(selectedCurrency.symbol)"
    }

    /// Format an amount in a specific target currency without any FX
    /// conversion. Caller is responsible for having the value in that
    /// currency already. Used by the multi-currency preview labels
    /// (e.g. the "≈ 1 900 ₽" hint under a foreign-currency input).
    func formatInCurrency(_ amount: Decimal, currency: CurrencyCode) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = currency.decimals
        formatter.minimumFractionDigits = currency.decimals
        let absAmount = abs(amount)
        let formatted = formatter.string(from: absAmount as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
    }

    func fetchRates() async {
        rates = await exchangeRateService.fetchRates(base: "USD")
    }
}

enum CurrencyCode: String, CaseIterable, Codable, Sendable {
    case rub = "RUB"
    case usd = "USD"
    case eur = "EUR"
    case vnd = "VND"
    case thb = "THB"
    case idr = "IDR"

    var symbol: String {
        switch self {
        case .rub: return "₽"
        case .usd: return "$"
        case .eur: return "€"
        case .vnd: return "₫"
        case .thb: return "฿"
        case .idr: return "Rp"
        }
    }

    var name: String {
        switch self {
        case .rub: return String(localized: "currency.rub")
        case .usd: return String(localized: "currency.usd")
        case .eur: return String(localized: "currency.eur")
        case .vnd: return String(localized: "currency.vnd")
        case .thb: return String(localized: "currency.thb")
        case .idr: return String(localized: "currency.idr")
        }
    }

    /// Number of decimal places for display (matches Telegram app)
    var decimals: Int {
        switch self {
        case .rub, .vnd, .thb, .idr: return 0
        case .usd, .eur: return 2
        }
    }
}
