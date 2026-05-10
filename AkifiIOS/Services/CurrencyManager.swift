import Foundation

@Observable @MainActor
final class CurrencyManager {
    var selectedCurrency: Currency = .rub {
        didSet {
            UserDefaults.standard.set(selectedCurrency.code, forKey: "selected_currency")
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
           let code = Currency(code: saved) {
            selectedCurrency = code
        }
        if let savedData = UserDefaults.standard.string(forKey: "data_currency"),
           let code = Currency(code: savedData) {
            dataCurrency = code
        }
        resetFormatters()
    }

    /// The currency that amounts are stored in (user's default currency from profile)
    var dataCurrency: Currency = .rub {
        didSet {
            UserDefaults.standard.set(dataCurrency.code, forKey: "data_currency")
        }
    }

    private func resetFormatters() {
        currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = selectedCurrency.code
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
        guard let from = rates[dataCurrency.code], from > 0,
              let to   = rates[selectedCurrency.code], to > 0 else {
            return amount
        }
        return amount / Decimal(from) * Decimal(to)
    }

    /// Convert amount from display currency back to data (base) currency.
    /// Same fail-safe contract as `convert(_:)`.
    func toBase(_ amountInDisplayCurrency: Decimal) -> Decimal {
        guard dataCurrency != selectedCurrency else { return amountInDisplayCurrency }
        guard let from = rates[dataCurrency.code], from > 0,
              let to   = rates[selectedCurrency.code], to > 0 else {
            return amountInDisplayCurrency
        }
        return amountInDisplayCurrency / Decimal(to) * Decimal(from)
    }

    /// Convert amount from base (data) currency to a specific account currency.
    func convertToAccountCurrency(_ amountInBase: Decimal, accountCurrency: Currency) -> Decimal {
        guard dataCurrency != accountCurrency else { return amountInBase }
        guard let from = rates[dataCurrency.code], from > 0,
              let to   = rates[accountCurrency.code], to > 0 else {
            return amountInBase
        }
        return amountInBase / Decimal(from) * Decimal(to)
    }

    /// Convert amount from a specific account currency back to base (data) currency.
    func convertFromAccountCurrency(_ amount: Decimal, accountCurrency: Currency) -> Decimal {
        guard dataCurrency != accountCurrency else { return amount }
        guard let from = rates[dataCurrency.code], from > 0,
              let to   = rates[accountCurrency.code], to > 0 else {
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
    func formatInCurrency(_ amount: Decimal, currency: Currency) -> String {
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

// `CurrencyCode` and the associated symbol/name/decimals API now live in
// `Currency.swift` (struct + ISO catalog). The old enum has been removed
// — `typealias CurrencyCode = Currency` keeps existing call sites compiling.
