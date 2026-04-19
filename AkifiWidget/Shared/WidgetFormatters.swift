import Foundation

/// Money / streak formatting helpers shared across all four widgets.
/// Widget extension does NOT link `CurrencyManager` (that service is
/// `@MainActor` and pulls in `ExchangeRateService`); instead we do the bare
/// minimum formatting right here using the snapshot's baked-in currency
/// metadata.
enum WidgetFormatters {

    /// Converts a kopeck Int64 into a display string like "125 000 ₽" or
    /// "1 250.50 $", using the snapshot's decimal/precision hints.
    ///
    /// Never throws, never returns nil — widgets can't afford mid-render
    /// failures.
    static func amount(_ kopecks: Int64, snapshot: SharedSnapshot, signed: Bool = false) -> String {
        let decimals = snapshot.baseCurrencyDecimals
        let divisor = pow(10.0, Double(2))            // kopecks → units is always /100
        let value = Double(kopecks) / divisor

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = decimals
        formatter.minimumFractionDigits = decimals
        formatter.groupingSeparator = " "
        formatter.usesGroupingSeparator = true

        let abs = Swift.abs(value)
        let body = formatter.string(from: NSNumber(value: abs)) ?? "0"
        let sign: String = {
            guard signed else { return "" }
            if value > 0 { return "+" }
            if value < 0 { return "−" }
            return ""
        }()

        // Put currency symbol after amount for RUB-style (symbol comes AFTER)
        // and before for USD/EUR. Matches how the main app displays amounts.
        let symbol = snapshot.baseCurrencySymbol
        switch snapshot.baseCurrency.uppercased() {
        case "USD", "EUR":
            return "\(sign)\(symbol)\(body)"
        default:
            return "\(sign)\(body) \(symbol)"
        }
    }

    /// Compact variant for tight spaces (small widget family, accessoryCircular).
    /// Uses "k" / "M" suffixes once the amount exceeds 10 000 units.
    static func compactAmount(_ kopecks: Int64, snapshot: SharedSnapshot) -> String {
        let units = Double(kopecks) / 100.0
        let abs = Swift.abs(units)
        let symbol = snapshot.baseCurrencySymbol
        let sign = units < 0 ? "−" : ""

        func format(_ v: Double, _ suffix: String) -> String {
            let rounded = (v * 10).rounded() / 10
            let nf = NumberFormatter()
            nf.maximumFractionDigits = rounded.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1
            nf.decimalSeparator = "."
            let body = nf.string(from: NSNumber(value: rounded)) ?? "0"
            return "\(sign)\(body)\(suffix) \(symbol)"
        }

        if abs >= 1_000_000 {
            return format(abs / 1_000_000, "M")
        } else if abs >= 10_000 {
            return format(abs / 1_000, "k")
        } else {
            return amount(kopecks, snapshot: snapshot)
        }
    }

    /// Human-readable streak count. `12` → `"12"`, pluralization handled by
    /// the caller via `String.localizedStringWithFormat` where needed.
    static func streakCount(_ days: Int) -> String {
        String(days)
    }
}
