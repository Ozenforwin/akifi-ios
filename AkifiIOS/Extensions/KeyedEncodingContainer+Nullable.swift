import Foundation

extension KeyedEncodingContainer {
    /// Double-optional field of a PATCH payload: `.none` → key omitted
    /// (column untouched), `.some(nil)` → JSON null (column cleared),
    /// `.some(x)` → x. A synthesized Encodable drops nil keys, so a field
    /// the user cleared was silently kept on the server (V4).
    mutating func encodeNullable<T: Encodable>(_ value: T??, forKey key: Key) throws {
        guard let value else { return }
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
