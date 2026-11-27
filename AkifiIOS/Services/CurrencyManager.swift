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
    /// Same as `decimalFormatter` minus the fractional part.
    private var wholeFormatter: NumberFormatter

    init() {
        currencyFormatter = NumberFormatter()
        decimalFormatter = NumberFormatter()
        wholeFormatter = NumberFormatter()

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

        wholeFormatter = NumberFormatter()
        wholeFormatter.numberStyle = .decimal
        wholeFormatter.maximumFractionDigits = 0
        wholeFormatter.minimumFractionDigits = 0
        wholeFormatter.roundingMode = .halfUp
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

    func format(_ amount: Decimal) -> String {
        let converted = convert(amount)
        return currencyFormatter.string(from: converted as NSDecimalNumber) ?? "0"
    }

    /// `wholeUnits: true` drops the fractional part — budgets read as
    /// «319 $ из 478 $», where cents are noise against a monthly limit.
    func formatAmount(_ amount: Decimal, wholeUnits: Bool = false) -> String {
        let absAmount = abs(amount)
        let converted = convert(absAmount)
        let formatter = wholeUnits ? wholeFormatter : decimalFormatter
        let formatted = formatter.string(from: converted as NSDecimalNumber) ?? "0"
        return "\(formatted) \(selectedCurrency.symbol)"
    }

    /// Format an amount in a specific target currency without any FX
    /// conversion. Caller is responsible for having the value in that
    /// currency already. Used by the multi-currency preview labels
    /// (e.g. the "≈ 1 900 ₽" hint under a foreign-currency input).
    func formatInCurrency(_ amount: Decimal, currency: Currency, wholeUnits: Bool = false) -> String {
        let formatter = fixedDigitsFormatter(wholeUnits ? 0 : currency.decimals)
        let absAmount = abs(amount)
        let formatted = formatter.string(from: absAmount as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
    }

    /// One decimal formatter per fraction-digit count. `formatInCurrency`
    /// runs for every transaction row on screen and used to build a new
    /// `NumberFormatter` per call (P6).
    @ObservationIgnored private var fixedDigitsFormatters: [Int: NumberFormatter] = [:]

    private func fixedDigitsFormatter(_ digits: Int) -> NumberFormatter {
        if let cached = fixedDigitsFormatters[digits] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        formatter.minimumFractionDigits = digits
        fixedDigitsFormatters[digits] = formatter
        return formatter
    }

    func fetchRates() async {
        let snapshot = await exchangeRateService.fetchRates(base: "USD")
        rates = snapshot.rates
        rateQuotedAt = snapshot.quotedAt
    }

    // MARK: - Write-path rates (M5)

    /// When each code in `rates` was quoted by the network or the server
    /// `fx_rates` table. Codes without an entry (hard-coded fallback, the
    /// instant-start cache seeded by `AppViewModel`) are display-only.
    @ObservationIgnored private(set) var rateQuotedAt: [String: Date] = [:]

    /// Rates a WRITE may freeze into `amount_native`: only quotes younger
    /// than `FXRateSnapshot.maxWriteAge`. Pass this — never `rates` — to
    /// `TransactionMath.convertForStorage`; a missing code makes the save
    /// fail with "no exchange rate" instead of storing a stale conversion.
    func writeRates(now: Date = Date()) -> [String: Double] {
        FXRateSnapshot(rates: rates, quotedAt: rateQuotedAt).writableRates(now: now)
    }

    /// `writeRates`, refreshed first when any of `codes` is missing or
    /// stale — so a form opened on a two-day-old cache re-quotes on Save
    /// when the network is back, and still refuses offline.
    func ratesForWrite(_ codes: [String]) async -> [String: Double] {
        let wanted = codes.map { $0.uppercased() }
        let current = writeRates()
        if wanted.allSatisfy({ current[$0] != nil }) { return current }
        await fetchRates()
        return writeRates()
    }

    /// Test seam: install a table with its quote times.
    func apply(_ snapshot: FXRateSnapshot) {
        rates = snapshot.rates
        rateQuotedAt = snapshot.quotedAt
    }
}

// `CurrencyCode` and the associated symbol/name/decimals API now live in
// `Currency.swift` (struct + ISO catalog). The old enum has been removed
// — `typealias CurrencyCode = Currency` keeps existing call sites compiling.
