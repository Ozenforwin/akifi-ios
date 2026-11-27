import Foundation

/// The one parser for numbers the user types into an amount or rate field.
///
/// `Decimal(string:)` stops at the first character it doesn't understand
/// and returns the prefix: "1500,75" → 1500 (kopecks lost), "0,5" → 0 (a
/// zero contribution saved). Every form that accepts a decimal comma goes
/// through here instead (V7).
///
/// Accepted: digits with one decimal separator, either "," or "."
/// ("1500,75", "1500.75", ",5"); grouping by spaces (incl. no-break and
/// narrow no-break spaces) or by the OTHER separator when both appear
/// ("1 234,56", "1.234,56", "1,234.56"); a repeated single separator is
/// grouping ("1.500.000"). Anything else — letters, a sign, two decimal
/// points of different kinds in the wrong order — is `nil`, never a prefix.
enum DecimalInput {

    static func parse(_ text: String) -> Decimal? {
        var s = text.filter { !$0.isWhitespace && $0 != "\u{00A0}" && $0 != "\u{202F}" && $0 != "'" }
        guard !s.isEmpty else { return nil }

        let commas = s.filter { $0 == "," }.count
        let dots = s.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            // Both present: the LAST one is the decimal separator, the other
            // is grouping.
            guard let lastComma = s.lastIndex(of: ","), let lastDot = s.lastIndex(of: ".") else { return nil }
            let decimal: Character = lastComma > lastDot ? "," : "."
            let grouping: Character = decimal == "," ? "." : ","
            guard s.filter({ $0 == decimal }).count == 1 else { return nil }
            s.removeAll { $0 == grouping }
            s = s.replacingOccurrences(of: String(decimal), with: ".")
        } else if commas > 1 || dots > 1 {
            // "1.500.000" / "1,500,000" — grouping only.
            s.removeAll { $0 == "," || $0 == "." }
        } else {
            s = s.replacingOccurrences(of: ",", with: ".")
        }

        guard s.contains(where: \.isNumber),
              s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        if s.hasPrefix(".") { s = "0" + s }
        if s.hasSuffix(".") { s.removeLast() }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Main units → kopecks (×100, ties away from zero — `MoneyRounding`).
    static func kopecks(_ text: String) -> Int64? {
        parse(text).map(MoneyRounding.kopecks)
    }
}
