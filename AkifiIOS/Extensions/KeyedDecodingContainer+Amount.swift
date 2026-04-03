import Foundation

extension KeyedDecodingContainer {
    /// Decode a DB numeric (rubles as String or Double) into Int64 kopecks.
    /// Also handles Int64 directly (for local JSON cache where kopecks are already stored).
    func decodeKopecks(forKey key: Key) -> Int64 {
        // Int64 first — local cache stores kopecks directly
        if let int = try? decode(Int64.self, forKey: key) {
            return int
        }
        // String — PostgREST sends numeric as string to preserve precision
        if let str = try? decode(String.self, forKey: key),
           let decimal = Decimal(string: str) {
            return Int64(truncating: (decimal * 100) as NSDecimalNumber)
        }
        // Double — fallback for JSON numbers
        if let dbl = try? decode(Double.self, forKey: key) {
            return Int64((dbl * 100).rounded())
        }
        return 0
    }

    /// Optional variant — returns nil when the key is absent or null.
    func decodeKopecksIfPresent(forKey key: Key) -> Int64? {
        if let int = try? decode(Int64.self, forKey: key) {
            return int
        }
        if let str = try? decode(String.self, forKey: key),
           let decimal = Decimal(string: str) {
            return Int64(truncating: (decimal * 100) as NSDecimalNumber)
        }
        if let dbl = try? decode(Double.self, forKey: key) {
            return Int64((dbl * 100).rounded())
        }
        return nil
    }
}
