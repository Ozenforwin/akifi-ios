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

/// The ONE rounding rule for money in the client (M12): half away from zero
/// — the same as Postgres `round(numeric)`, which `get_account_settlement`
/// and the other server aggregates use. Every path that turns a main-unit
/// amount into kopecks (DB decode, cache decode, offline placeholders, FX
/// conversion at entry time) goes through here, so a row can never be one
/// kopeck apart between two code paths (or between a phone and the server).
enum MoneyRounding {

    /// `value` rounded to `scale` fraction digits, ties away from zero
    /// (`NSDecimalNumber.RoundingMode.plain`: 0.005 → 0.01, −0.005 → −0.01).
    static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    /// Main units → kopecks (×100), ties away from zero.
    static func kopecks(_ value: Decimal) -> Int64 {
        Int64(truncating: rounded(value * 100, scale: 0) as NSDecimalNumber)
    }

    /// A JSON number arrives as a binary `Double`; `Decimal(0.285)` is
    /// 0.28499999…, which would round DOWN. The shortest round-trip
    /// description ("0.285") is the number the server actually sent, so
    /// decode through it.
    static func decimal(fromJSONNumber value: Double) -> Decimal {
        Decimal(string: String(value)) ?? Decimal(value)
    }

    /// Fraction digits we can actually persist for `currencyCode`.
    /// Amounts are stored as kopecks (×100), so the cap is 2: a third digit
    /// (KWD/BHD/OMR) cannot be represented and is rounded here, visibly,
    /// instead of being silently truncated later. Zero-decimal ISO
    /// currencies (JPY, KRW, VND, CLP…) round to whole units so an FX
    /// conversion never invents fractional yen.
    ///
    /// ISO-4217 digits (via an `en_US` currency formatter), NOT
    /// `CurrencyCatalog.decimals` — that one is a display preference
    /// (RUB/THB/IDR are shown without kopecks but do store them).
    /// Only called on the save path (once per FX conversion), so the
    /// formatter is not cached.
    static func storageScale(forCurrency code: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = code.uppercased()
        return min(2, max(0, formatter.minimumFractionDigits))
    }

    /// `amount` (main units of `currencyCode`) rounded to what can be stored.
    static func roundedForStorage(_ amount: Decimal, currency code: String) -> Decimal {
        rounded(amount, scale: storageScale(forCurrency: code))
    }
}

extension Decimal {
    /// Main units → kopecks (×100), half away from zero — see `MoneyRounding`.
    /// Counterpart of `Int64.displayAmount`.
    var kopecks: Int64 { MoneyRounding.kopecks(self) }
}
