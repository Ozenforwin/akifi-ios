import Foundation

/// Names of account cover objects in the private `account-covers` bucket
/// (migration 20261128100000): `<account_id>/<uuid>.jpg`, both lower-case.
///
/// A name is never reused — a new cover is a new uuid — so a cached image
/// is valid for as long as an account points at its name. The server
/// enforces the same shape (`accounts_cover_path_check` and the storage
/// policies); `isValid` mirrors it so the client never sends or caches
/// anything else.
enum AccountCoverPath {
    static let bucket = "account-covers"

    /// A fresh object name for a new cover of `accountId`.
    static func make(accountId: String, objectId: UUID = UUID()) -> String {
        "\(accountId.lowercased())/\(objectId.uuidString.lowercased()).jpg"
    }

    /// `path` has the exact server shape — and, with `accountId`, belongs
    /// to that account.
    static func isValid(_ path: String?, accountId: String? = nil) -> Bool {
        guard let path, path.utf8.count == 77, path.hasSuffix(".jpg") else { return false }
        let parts = path.dropLast(4).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              isLowercaseUUID(parts[0]),
              isLowercaseUUID(parts[1]) else { return false }
        if let accountId {
            return String(parts[0]) == accountId.lowercased()
        }
        return true
    }

    /// The account a valid cover belongs to.
    static func accountId(of path: String) -> String? {
        guard isValid(path) else { return nil }
        return path.split(separator: "/").first.map(String.init)
    }

    /// Flat file name for the on-disk cache (`<account>_<uuid>.jpg`); nil
    /// for anything that isn't a valid cover name, so a server value can
    /// never steer a write outside the cache directory.
    static func cacheFileName(for path: String) -> String? {
        guard isValid(path) else { return nil }
        return path.replacingOccurrences(of: "/", with: "_")
    }

    private static func isLowercaseUUID(_ text: Substring) -> Bool {
        guard text.utf8.count == 36, UUID(uuidString: String(text)) != nil else { return false }
        return text.allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Who may change an account's cover. Decided with Vladimir (1.6.0): the
/// OWNER sets it, every member of a shared account sees the same cover,
/// nobody else may change or remove it; a debt account has none. The server
/// enforces the same (`guard_account_cover`, storage policies).
enum AccountCoverPolicy {
    /// The edit controls («Выбрать фото», «Изменить область», «Убрать
    /// обложку») are shown.
    static func canEdit(_ account: Account, viewerId: String?) -> Bool {
        guard let viewerId, !viewerId.isEmpty, supportsCover(account) else { return false }
        return account.userId.lowercased() == viewerId.lowercased()
    }

    /// The «Обложка» section exists at all (debt accounts have no cover).
    static func supportsCover(_ account: Account) -> Bool {
        account.accountType != .debt
    }
}
