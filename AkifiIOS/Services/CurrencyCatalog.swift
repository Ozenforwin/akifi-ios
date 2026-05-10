import Foundation

/// Per-currency overrides loaded from `CurrencyOverrides.json`.
///
/// Used to correct three categories of Apple defaults:
/// 1. Wrong symbol (RUB returns "RUB" on some locales instead of "₽").
/// 2. Wrong fraction digits (RUB / KZT / VND / THB / IDR are de-facto
///    integer currencies even though ISO says they have fractional units).
/// 3. Newer ISO codes Apple hasn't picked up yet.
struct CurrencyOverride: Codable, Sendable {
    let symbol: String?
    let decimals: Int?
}

/// Static catalog of supported currencies.
///
/// **Source of truth:** `Locale.commonISOCurrencyCodes` (Apple's curated
/// list of ~150 active ISO-4217 codes — already filtered for non-3-char
/// noise, but we re-filter defensively).
///
/// **Why static (no DI):** the catalog is pure compute over `Locale` +
/// a bundled JSON. There's nothing to mock and no per-instance state.
/// Treating it as a global namespace keeps call sites readable
/// (`CurrencyCatalog.byCode("USD")` reads better than threading an
/// instance through every form view).
enum CurrencyCatalog {

    // MARK: - Public API

    /// All supported currencies, sorted ASC by ISO code. Stable across
    /// launches because `Locale.commonISOCurrencyCodes` is itself stable.
    static let all: [Currency] = {
        let codes = (Locale.commonISOCurrencyCodes)
            .map { $0.uppercased() }
            .filter { $0.count == 3 && $0.allSatisfy(\.isLetter) }
        let unique = Array(Set(codes)).sorted()
        return unique.map { Currency(unchecked: $0) }
    }()

    /// Currencies pinned to the top of the picker.
    /// Order is hand-curated for the Akifi user base (USD/EUR for global,
    /// RUB for ru-locale users, then high-traffic FX corridors).
    static let popular: [Currency] = {
        let order = ["USD", "EUR", "RUB", "GBP", "JPY", "CNY",
                     "KZT", "GEL", "TRY", "THB", "VND", "IDR"]
        return order.compactMap { byCode($0) }
    }()

    /// Case-insensitive lookup. Returns `nil` for non-ISO / unknown codes.
    static func byCode(_ code: String) -> Currency? {
        let upper = code.uppercased()
        guard isKnown(upper) else { return nil }
        return Currency(unchecked: upper)
    }

    /// `true` if `code` (case-insensitive) appears in
    /// `Locale.commonISOCurrencyCodes`. Cheap O(1) via the cached set.
    static func isKnown(_ code: String) -> Bool {
        guard !code.isEmpty else { return false }
        return knownCodes.contains(code.uppercased())
    }

    /// Search by code OR localized name, case-insensitive.
    /// Empty query returns the full sorted list.
    static func search(_ query: String) -> [Currency] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        let needle = q.lowercased()
        return all.filter { c in
            c.code.lowercased().contains(needle)
                || c.localizedName.lowercased().contains(needle)
        }
    }

    // MARK: - Symbol / name / decimals (used by `Currency` computed props)

    static func symbol(for code: String) -> String {
        let upper = code.uppercased()
        if let override = overrides[upper]?.symbol { return override }

        // Fixed `en_US` locale: avoids the well-known
        // "$ for USD AND CAD" collapse that happens in non-en locales.
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = upper
        if let symbol = formatter.currencySymbol, !symbol.isEmpty, symbol != upper {
            return symbol
        }
        return upper
    }

    static func localizedName(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code.uppercased()
    }

    static func decimals(for code: String) -> Int {
        let upper = code.uppercased()
        if let override = overrides[upper]?.decimals { return override }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = upper
        // `minimumFractionDigits` of a `.currency` formatter reflects the
        // ISO-4217 default for that code (2 for most, 0 for JPY, 3 for
        // BHD, …). Good enough as a fallback.
        return max(0, formatter.minimumFractionDigits)
    }

    // MARK: - Overrides loader

    /// Lazy-loaded overrides. Falls back to a hard-coded constant when the
    /// JSON resource is missing (test bundles, broken builds, …) so that
    /// the app *never* renders RUB as "RUB" when the override is the only
    /// thing keeping it as "₽".
    static let overrides: [String: CurrencyOverride] = {
        if let url = Bundle.main.url(forResource: "CurrencyOverrides", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: CurrencyOverride].self, from: data) {
            return decoded
        }
        // Fallback — keeps the symbols correct even if the resource
        // doesn't make it into the bundle for some reason.
        return [
            "RUB": .init(symbol: "₽", decimals: 0),
            "VND": .init(symbol: "₫", decimals: 0),
            "THB": .init(symbol: "฿", decimals: 0),
            "IDR": .init(symbol: "Rp", decimals: 0),
            "KZT": .init(symbol: "₸", decimals: 0),
            "GEL": .init(symbol: "₾", decimals: nil),
            "TRY": .init(symbol: "₺", decimals: nil),
        ]
    }()

    // MARK: - Internals

    private static let knownCodes: Set<String> = {
        let base = (Locale.commonISOCurrencyCodes)
            .map { $0.uppercased() }
            .filter { $0.count == 3 && $0.allSatisfy(\.isLetter) }
        // Make sure every override-curated code is recognised even when
        // Apple's list temporarily drops one (defensive, keeps the
        // legacy 9 codes — RUB, KZT, GEL, TRY, … — always valid).
        let curated = ["RUB", "USD", "EUR", "VND", "THB", "IDR",
                       "KZT", "GEL", "TRY", "GBP", "JPY", "CNY"]
        return Set(base).union(curated)
    }()
}
