import Foundation

extension KeyedDecodingContainer {
    /// Decode a DB numeric (rubles as String, Double, or Int) into Int64 kopecks.
    /// Always treats the source value as RUBLES and multiplies by 100.
    func decodeKopecks(forKey key: Key) -> Int64 {
        // String first — PostgREST sends numeric as string to preserve precision
        if let str = try? decode(String.self, forKey: key),
           let decimal = Decimal(string: str) {
            return Int64(truncating: (decimal * 100) as NSDecimalNumber)
        }
        // Double — JSON numbers (both DB and cache)
        if let dbl = try? decode(Double.self, forKey: key) {
            return Int64((dbl * 100).rounded())
        }
        return 0
    }

    /// Optional variant — returns nil when the key is absent or null.
    func decodeKopecksIfPresent(forKey key: Key) -> Int64? {
        if let str = try? decode(String.self, forKey: key),
           let decimal = Decimal(string: str) {
            return Int64(truncating: (decimal * 100) as NSDecimalNumber)
        }
        if let dbl = try? decode(Double.self, forKey: key) {
            return Int64((dbl * 100).rounded())
        }
        return nil
    }

    /// Decode a DB numeric into Decimal in its own units (no ×100).
    /// Used for values where the unit is currency-dependent (e.g. VND has no
    /// minor unit, USD has cents) or where the value is a rate, not an amount.
    func decodeDecimalIfPresent(forKey key: Key) -> Decimal? {
        if let str = try? decode(String.self, forKey: key),
           let decimal = Decimal(string: str) {
            return decimal
        }
        if let dbl = try? decode(Double.self, forKey: key) {
            return Decimal(dbl)
        }
        return nil
    }
}
