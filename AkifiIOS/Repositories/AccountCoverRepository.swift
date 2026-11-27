import Foundation
import Supabase

/// The server side of account covers — the seam `AccountCoverStore` uses
/// (tests replace it with a fake).
protocol AccountCoverRemote: Sendable {
    /// The cover's bytes, through the authenticated Storage API.
    func download(path: String) async throws -> Data
    /// Creates the object (never overwrites — names are unique).
    func upload(jpeg: Data, path: String) async throws
    /// Points `accounts.cover_path` at `path` (nil removes the cover).
    func setCoverPath(_ path: String?, accountId: String) async throws
    /// Sets `accounts.cover_dim` (nil = automatic).
    func setCoverDim(_ dim: Int?, accountId: String) async throws
    /// Deletes objects; already-missing ones are not an error.
    func removeObjects(paths: [String]) async throws
    /// Every object in the account's folder (at most one page).
    func listObjects(accountId: String) async throws -> [String]
}

enum AccountCoverError: LocalizedError, Equatable {
    /// The row update matched nothing: not the owner (RLS hid the row or
    /// let it through unchanged) or the account is gone.
    case notPermitted
    /// The picked file couldn't be read or decoded as an image.
    case unreadableImage
    /// Cropping / encoding failed.
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notPermitted: String(localized: "account.cover.error.ownerOnly")
        case .unreadableImage: String(localized: "account.cover.error.unreadable")
        case .encodingFailed: String(localized: "account.cover.error.upload")
        }
    }
}

/// Supabase access for account covers (migration 20261128100000): the
/// private `account-covers` bucket and `accounts.cover_path`.
///
/// No public or signed URLs: images are downloaded with the session's
/// bearer token in the `Authorization` header (`download(path:)`), so no
/// token ever sits in a URL, a log line or a cache key.
final class AccountCoverRepository: AccountCoverRemote {
    static let bucket = AccountCoverPath.bucket

    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    private var storage: StorageFileApi { client.storage.from(Self.bucket) }

    func download(path: String) async throws -> Data {
        try await storage.download(path: path)
    }

    func upload(jpeg: Data, path: String) async throws {
        // max-age 0: no shared cache keeps a copy of a private cover; the
        // app has its own (names are immutable, `AccountCoverStore`).
        try await storage.upload(
            path,
            data: jpeg,
            options: FileOptions(cacheControl: "0", contentType: "image/jpeg", upsert: false)
        )
    }

    func setCoverPath(_ path: String?, accountId: String) async throws {
        struct Row: Decodable { let id: String }
        let rows: [Row] = try await client
            .from("accounts")
            .update(CoverPatch(coverPath: path))
            .eq("id", value: accountId)
            .select("id")
            .execute()
            .value
        // A viewer's (or stranger's) UPDATE is filtered away by RLS: zero
        // rows and no error. Never report that as "saved".
        guard !rows.isEmpty else { throw AccountCoverError.notPermitted }
    }

    func setCoverDim(_ dim: Int?, accountId: String) async throws {
        struct Row: Decodable { let id: String }
        let rows: [Row] = try await client
            .from("accounts")
            .update(DimPatch(coverDim: dim.map { min(max($0, 0), 100) }))
            .eq("id", value: accountId)
            .select("id")
            .execute()
            .value
        guard !rows.isEmpty else { throw AccountCoverError.notPermitted }
    }

    func removeObjects(paths: [String]) async throws {
        let valid = paths.filter { AccountCoverPath.isValid($0) }
        guard !valid.isEmpty else { return }
        try await storage.remove(paths: valid)
    }

    func listObjects(accountId: String) async throws -> [String] {
        let folder = accountId.lowercased()
        // A folder holds the current cover plus, at worst, a few left over
        // from best-effort deletes — one page of 100 is plenty.
        let objects = try await storage.list(path: folder, options: SearchOptions(limit: 100))
        return objects
            .map { "\(folder)/\($0.name)" }
            .filter { AccountCoverPath.isValid($0, accountId: folder) }
    }

    /// `{"cover_path": <path or null>}` — an explicit null clears the
    /// column (a synthesized Encodable would drop a nil key).
    struct CoverPatch: Encodable {
        let coverPath: String?

        enum CodingKeys: String, CodingKey { case coverPath = "cover_path" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(coverPath, forKey: .coverPath)
        }
    }
}

extension AccountCoverRepository {
    /// `{"cover_dim": <0…100 or null>}` — an explicit null returns to
    /// automatic.
    struct DimPatch: Encodable {
        let coverDim: Int?

        enum CodingKeys: String, CodingKey { case coverDim = "cover_dim" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(coverDim, forKey: .coverDim)
        }
    }
}

/// User-facing text for a failed cover change.
enum AccountCoverErrorMessage {
    static func text(for error: Error) -> String {
        if let cover = error as? AccountCoverError {
            return cover.errorDescription ?? String(localized: "account.cover.error.upload")
        }
        if let pg = error as? PostgrestError {
            switch pg.code {
            case "42501":
                return String(localized: "account.cover.error.ownerOnly")
            case "PGRST204", "PGRST205", "42703":
                // The server has no cover_path column yet.
                return String(localized: "server.error.featureNotReady")
            default:
                return String(localized: "account.cover.error.upload")
            }
        }
        if let storage = error as? StorageError {
            if storage.message.localizedCaseInsensitiveContains("bucket not found") {
                return String(localized: "server.error.featureNotReady")
            }
            if storage.statusCode == "403" || storage.message.localizedCaseInsensitiveContains("row-level security") {
                return String(localized: "account.cover.error.ownerOnly")
            }
            if storage.statusCode == "413" || storage.message.localizedCaseInsensitiveContains("too large") {
                return String(localized: "account.cover.error.tooLarge")
            }
        }
        if error is URLError {
            return String(localized: "account.cover.error.offline")
        }
        return String(localized: "account.cover.error.upload")
    }
}
