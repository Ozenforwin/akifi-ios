import Foundation

extension KeyedDecodingContainer {
    /// Decode a DB numeric (main units as String, Double, or Int) into Int64
    /// kopecks (×100). Rounds half away from zero through `MoneyRounding` —
    /// the same rule as `Decimal.kopecks` and Postgres `round()`, on every
    /// path (M12: the string path used to truncate while the number path
    /// rounded, so the same value could land one kopeck apart).
    func decodeKopecks(forKey key: Key) -> Int64 {
        decodeKopecksIfPresent(forKey: key) ?? 0
    }

    /// Optional variant — returns nil when the key is absent or null.
    func decodeKopecksIfPresent(forKey key: Key) -> Int64? {
        decodeDecimalIfPresent(forKey: key).map(MoneyRounding.kopecks)
    }

    /// Decode a DB numeric into Decimal in its own units (no ×100).
    /// Used for values where the unit is currency-dependent (e.g. VND has no
    /// minor unit, USD has cents) or where the value is a rate, not an amount.
    func decodeDecimalIfPresent(forKey key: Key) -> Decimal? {
        // String first — PostgREST may send numeric as a string to keep precision.
        if let str = try? decode(String.self, forKey: key),
           let decimal = Decimal(string: str) {
            return decimal
        }
        // JSON number (DB and the on-disk cache): go through its shortest
        // decimal description, not the binary Double — see MoneyRounding.
        if let dbl = try? decode(Double.self, forKey: key) {
            return MoneyRounding.decimal(fromJSONNumber: dbl)
        }
        return nil
    }
}
