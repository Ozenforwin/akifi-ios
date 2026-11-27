import CryptoKit
import Foundation

/// A UUID derived from a name instead of drawn at random.
///
/// Used as the client-generated primary key of rows that must be written
/// exactly once even when the write is retried: the same inputs always give
/// the same id, so a retry after a half-finished batch fails with 23505 on
/// the rows that already landed instead of inserting them a second time
/// (bank-statement import, deposit payout legs).
///
/// SHA-256 of the parts, first 16 bytes, RFC 4122 version/variant bits set
/// (version 5 layout, SHA-256 instead of SHA-1). Parts are joined with the
/// ASCII unit separator so `("ab", "c")` and `("a", "bc")` differ.
enum DeterministicUUID {

    static func make(_ parts: String...) -> String {
        make(parts: parts)
    }

    static func make(parts: [String]) -> String {
        let name = parts.joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
