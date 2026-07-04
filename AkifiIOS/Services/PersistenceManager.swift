import Foundation
import os

/// JSON file-based offline cache for app data.
/// Stores data in Application Support/OfflineData/ — survives app restarts
/// and is NOT purgeable by the system (the offline write queue lives here,
/// losing it would lose user transactions). Excluded from iCloud backup:
/// the server is the source of truth, and a queue restored onto a new
/// device must not replay stale operations.
final class PersistenceManager: Sendable {
    static let shared = PersistenceManager()

    /// Set on `encoder.userInfo` so DTOs can persist client-only fields
    /// (queue replay flags) that must never appear in network payloads.
    static let queuePersistenceKey = CodingUserInfoKey(rawValue: "akifi.queuePersistence")!

    private let dir: URL
    /// JSONEncoder / JSONDecoder may not conform to Sendable on all
    /// SDK versions. They are only used sequentially inside save/load,
    /// so nonisolated(unsafe) is safe here.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.userInfo[PersistenceManager.queuePersistenceKey] = true
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Increment when encode format changes to invalidate stale cache
    private static let cacheVersion = 2

    /// Filenames that survive `migrateIfNeeded`'s cache invalidation —
    /// they hold not-yet-synced user writes, not re-fetchable data.
    private static let queueFilenames = ["pending_ops.json", "dead_letter_ops.json"]

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newDir = appSupport.appendingPathComponent("OfflineData", isDirectory: true)
        // One-time migration from the old purgeable Caches location —
        // pending_ops.json moves along with the rest.
        let oldDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OfflineData", isDirectory: true)
        if !FileManager.default.fileExists(atPath: newDir.path),
           FileManager.default.fileExists(atPath: oldDir.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: oldDir, to: newDir)
        }
        self.init(directory: newDir)
    }

    /// Designated init — internal so tests can point at a temp directory.
    init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeFromBackup()
        migrateIfNeeded()
    }

    private func excludeFromBackup() {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func migrateIfNeeded() {
        let key = "offline_cache_version"
        let stored = UserDefaults.standard.integer(forKey: key)
        if stored < Self.cacheVersion {
            clearAll(preservingQueue: true)
            UserDefaults.standard.set(Self.cacheVersion, forKey: key)
        }
    }

    // MARK: - Generic save/load

    func save<T: Encodable>(_ data: T, filename: String) {
        do {
            let fileURL = dir.appendingPathComponent(filename)
            let json = try encoder.encode(data)
            try json.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.data.debug("Cache save failed (\(filename)): \(error)")
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let fileURL = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Typed helpers

    func saveTransactions(_ items: [Transaction]) { save(items, filename: "transactions.json") }
    func loadTransactions() -> [Transaction]? { load([Transaction].self, filename: "transactions.json") }

    func saveAccounts(_ items: [Account]) { save(items, filename: "accounts.json") }
    func loadAccounts() -> [Account]? { load([Account].self, filename: "accounts.json") }

    func saveCategories(_ items: [Category]) { save(items, filename: "categories.json") }
    func loadCategories() -> [Category]? { load([Category].self, filename: "categories.json") }

    func saveBudgets(_ items: [Budget]) { save(items, filename: "budgets.json") }
    func loadBudgets() -> [Budget]? { load([Budget].self, filename: "budgets.json") }

    func saveSubscriptions(_ items: [SubscriptionTracker]) { save(items, filename: "subscriptions.json") }
    func loadSubscriptions() -> [SubscriptionTracker]? { load([SubscriptionTracker].self, filename: "subscriptions.json") }

    func saveProfile(_ item: Profile) { save(item, filename: "profile.json") }
    func loadProfile() -> Profile? { load(Profile.self, filename: "profile.json") }

    func saveNotes(_ items: [FinancialNote]) { save(items, filename: "notes.json") }
    func loadNotes() -> [FinancialNote]? { load([FinancialNote].self, filename: "notes.json") }

    func savePendingOps(_ ops: [PendingOperation]) { save(ops, filename: "pending_ops.json") }
    func loadPendingOps() -> [PendingOperation]? { load([PendingOperation].self, filename: "pending_ops.json") }

    func saveDeadLetterOps(_ ops: [PendingOperation]) { save(ops, filename: "dead_letter_ops.json") }
    func loadDeadLetterOps() -> [PendingOperation]? { load([PendingOperation].self, filename: "dead_letter_ops.json") }

    /// Remove cached data. Full wipe on sign-out (queued ops belong to the
    /// signed-out user); `preservingQueue: true` keeps pending/dead-letter
    /// ops across cache-format migrations.
    func clearAll(preservingQueue: Bool = false) {
        guard preservingQueue else {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            excludeFromBackup()
            return
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in contents where !Self.queueFilenames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
