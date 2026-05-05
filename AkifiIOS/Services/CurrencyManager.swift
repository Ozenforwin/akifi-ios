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

    /// Convert amount from data currency to selected display currency.
    /// Returns the input unchanged when either rate is missing — a missing
    /// entry coerced to 1.0 produces catastrophic results (see ADR-001 and
    /// the 2 000 000 VND → 26 315 USD incident, 2026-04-19).
    func convert(_ amount: Decimal) -> Decimal {
        guard dataCurrency != selectedCurrency else { return amount }
        guard let from = rates[dataCurrency.rawValue], from > 0,
              let to   = rates[selectedCurrency.rawValue], to > 0 else {
            return amount
        }
        return amount / Decimal(from) * Decimal(to)
    }

    /// Convert amount from display currency back to data (base) currency.
    /// Same fail-safe contract as `convert(_:)`.
    func toBase(_ amountInDisplayCurrency: Decimal) -> Decimal {
        guard dataCurrency != selectedCurrency else { return amountInDisplayCurrency }
        guard let from = rates[dataCurrency.rawValue], from > 0,
              let to   = rates[selectedCurrency.rawValue], to > 0 else {
            return amountInDisplayCurrency
        }
        return amountInDisplayCurrency / Decimal(to) * Decimal(from)
    }

    /// Convert amount from base (data) currency to a specific account currency.
    func convertToAccountCurrency(_ amountInBase: Decimal, accountCurrency: CurrencyCode) -> Decimal {
        guard dataCurrency != accountCurrency else { return amountInBase }
        guard let from = rates[dataCurrency.rawValue], from > 0,
              let to   = rates[accountCurrency.rawValue], to > 0 else {
            return amountInBase
        }
        return amountInBase / Decimal(from) * Decimal(to)
    }

    /// Convert amount from a specific account currency back to base (data) currency.
    func convertFromAccountCurrency(_ amount: Decimal, accountCurrency: CurrencyCode) -> Decimal {
        guard dataCurrency != accountCurrency else { return amount }
        guard let from = rates[dataCurrency.rawValue], from > 0,
              let to   = rates[accountCurrency.rawValue], to > 0 else {
            return amount
        }
        return amount / Decimal(to) * Decimal(from)
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
    case kzt = "KZT"
    case gel = "GEL"
    case `try` = "TRY"

    var symbol: String {
        switch self {
        case .rub: return "₽"
        case .usd: return "$"
        case .eur: return "€"
        case .vnd: return "₫"
        case .thb: return "฿"
        case .idr: return "Rp"
        case .kzt: return "₸"
        case .gel: return "₾"
        case .try: return "₺"
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
        case .kzt: return String(localized: "currency.kzt")
        case .gel: return String(localized: "currency.gel")
        case .try: return String(localized: "currency.try")
        }
    }

    /// Number of decimal places for display (matches Telegram app).
    /// KZT — по факту тенге пишут без тийинов, как RUB.
    /// GEL/TRY — реально дробятся на 100 (тетри / куруш).
    var decimals: Int {
        switch self {
        case .rub, .vnd, .thb, .idr, .kzt: return 0
        case .usd, .eur, .gel, .try: return 2
        }
    }
}
