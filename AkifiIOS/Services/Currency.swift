import Foundation

/// ISO-4217 currency value object.
///
/// Replaces the old `enum CurrencyCode` (closed list of 9 hard-coded cases)
/// with an open ISO-backed catalog driven by `Locale.commonISOCurrencyCodes`
/// and a small bundled override file (`CurrencyOverrides.json`) for the
/// handful of currencies where Apple's defaults disagree with what
/// finance users expect (RUB symbol, KZT decimals, …).
///
/// ## Backwards compatibility
/// The old `CurrencyCode` is preserved as a `typealias Currency` so the
/// 100+ existing call sites keep compiling. `init?(rawValue:)` and
/// `var rawValue` are kept as deprecated shims so legacy `.rawValue`
/// reads (UserDefaults, Supabase JSON, …) still work without a wire-format
/// migration. The 9 old static cases (`.rub`, `.usd`, …) are exposed as
/// `static let` accessors built from the catalog.
///
/// ## Codable
/// `Currency` encodes/decodes as a single ISO string ("USD"), not as an
/// object. This matches the existing wire format used by the Supabase
/// schema (`transactions.currency: TEXT`) and by every legacy JSON snapshot.
struct Currency: Codable, Hashable, Sendable, Identifiable {
    /// Uppercase ISO-4217 code (e.g. "USD", "RUB").
    let code: String

    var id: String { code }

    /// Currency symbol. Honours `CurrencyOverrides.json` first, then falls
    /// back to a fixed `en_US` `NumberFormatter`. We intentionally avoid
    /// `Locale.current` here because, in a Russian locale, `currencySymbol`
    /// returns "$" for both USD *and* CAD (they collapse to the same
    /// "dollar" gloss), which breaks user trust.
    var symbol: String { CurrencyCatalog.symbol(for: code) }

    /// Localized human name (e.g. "Доллар США" in ru, "US Dollar" in en).
    var localizedName: String { CurrencyCatalog.localizedName(for: code) }

    /// Number of fractional digits to display. Honours overrides first
    /// (RUB → 0 even though Apple returns 2), then falls back to the
    /// formatter-derived default.
    var decimals: Int { CurrencyCatalog.decimals(for: code) }

    // MARK: - Init

    /// Failable init. Returns `nil` for unknown / non-ISO codes so callers
    /// fail loud instead of writing garbage rows. Always uppercases input.
    init?(code: String) {
        let upper = code.uppercased()
        guard CurrencyCatalog.isKnown(upper) else { return nil }
        self.code = upper
    }

    /// Unchecked init. Used by `CurrencyCatalog` itself when seeding the
    /// canonical list and by the `static let` accessors below — both
    /// contexts where we control the input. Do not use from app code.
    init(unchecked code: String) {
        self.code = code.uppercased()
    }

    // MARK: - Codable (single-value String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Tolerant decode: accept any 3-char string. We don't reject
        // unknown codes here because legacy snapshots may have currencies
        // that the bundled catalog doesn't know about yet (e.g. a new
        // ISO code) — we'd rather show "ABC" in the UI than crash JSON
        // decode of an entire transactions list.
        self.code = raw.uppercased()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    // MARK: - Backwards-compat shims

    /// Legacy initialiser for code that still calls `CurrencyCode(rawValue:)`.
    /// Routes through the validating `init?(code:)`.
    @available(*, deprecated, renamed: "init(code:)")
    init?(rawValue: String) {
        self.init(code: rawValue)
    }

    /// Legacy accessor for code that still reads `.rawValue` (UserDefaults,
    /// dictionary keys, FX rate lookups). Returns the canonical uppercase
    /// ISO code — same wire format as the old enum.
    @available(*, deprecated, renamed: "code")
    var rawValue: String { code }

    /// Legacy accessor for the localized name (old enum exposed `.name`).
    @available(*, deprecated, renamed: "localizedName")
    var name: String { localizedName }
}

// MARK: - Static accessors (1:1 with old enum cases)

extension Currency {
    static let rub = Currency(unchecked: "RUB")
    static let usd = Currency(unchecked: "USD")
    static let eur = Currency(unchecked: "EUR")
    static let vnd = Currency(unchecked: "VND")
    static let thb = Currency(unchecked: "THB")
    static let idr = Currency(unchecked: "IDR")
    static let kzt = Currency(unchecked: "KZT")
    static let gel = Currency(unchecked: "GEL")
    static let `try` = Currency(unchecked: "TRY")
}

/// Source-compatibility alias. The old enum was named `CurrencyCode`;
/// keeping the typealias means the 100+ existing references to that
/// type compile unchanged after this refactor.
typealias CurrencyCode = Currency
