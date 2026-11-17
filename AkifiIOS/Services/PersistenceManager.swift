import Foundation
import os

/// Everything `DataStore` caches for offline / instant start, decoded in
/// one background pass by `PersistenceManager.loadDataSnapshot()`.
struct CachedDataSnapshot: Sendable {
    var accounts: [Account]?
    var transactions: [Transaction]?
    var categories: [Category]?
    var budgets: [Budget]?
    var subscriptions: [SubscriptionTracker]?
    var profile: Profile?

    var isEmpty: Bool {
        (accounts ?? []).isEmpty && (transactions ?? []).isEmpty
    }
}

/// JSON file-based offline cache for app data.
/// Stores data in Application Support/OfflineData/ — survives app restarts
/// and is NOT purgeable by the system (the offline write queue lives here,
/// losing it would lose user transactions). Excluded from iCloud backup:
/// the server is the source of truth, and a queue restored onto a new
/// device must not replay stale operations.
///
/// Two write paths:
/// - **Synchronous** (`save`, `savePendingOps`, …) — the offline queue. A
///   queued write is the only copy of the user's entry, so it hits the disk
///   before the call returns.
/// - **Background** (`saveInBackground`, `writeInBackground`) — re-fetchable
///   data caches (transactions, accounts, …). Encoding ~1 300 transactions
///   and writing six files used to run on the main thread after every
///   `loadAll`. Writes for the same file coalesce (latest value wins) on a
///   serial utility queue; `clearAll()` drops anything still pending, so a
///   late write can never resurrect a signed-out user's data.
final class PersistenceManager: Sendable {
    static let shared = PersistenceManager()

    /// Set on `encoder.userInfo` so DTOs can persist client-only fields
    /// (queue replay flags) that must never appear in network payloads.
    static let queuePersistenceKey = CodingUserInfoKey(rawValue: "akifi.queuePersistence")!

    private let dir: URL

    /// Fresh encoder per call: `JSONEncoder` is a mutable class and the
    /// background queue, the main actor and `DataStore`'s comparison tasks
    /// all encode concurrently. `.sortedKeys` makes the bytes a stable
    /// fingerprint — `DataStore` compares encodings to skip equal writes.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        e.userInfo[PersistenceManager.queuePersistenceKey] = true
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Serial queue for background cache writes and snapshot reads. Reads
    /// run on it too, so they always observe completed writes.
    private let ioQueue = DispatchQueue(label: "ru.akifi.persistence", qos: .utility)

    private struct PendingWrite: Sendable {
        let encode: @Sendable () throws -> Data
    }

    private struct WriterState: Sendable {
        /// Bumped by `clearAll()`; queued writes from an older generation
        /// are dropped.
        var generation: UInt64 = 0
        var pending: [String: PendingWrite] = [:]
    }

    private let writerState = OSAllocatedUnfairLock(initialState: WriterState())

    /// Increment when encode format changes to invalidate stale cache
    private static let cacheVersion = 2

    /// Filenames that survive `migrateIfNeeded`'s cache invalidation and a
    /// queue-preserving `clearAll` — they hold not-yet-synced user writes,
    /// not re-fetchable data.
    private static let queueFilenames = ["pending_ops.json", "dead_letter_ops.json", "queue_owner.json"]

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

    // MARK: - Generic save/load (synchronous)

    func save<T: Encodable>(_ data: T, filename: String) {
        do {
            let json = try Self.makeEncoder().encode(data)
            try json.write(to: dir.appendingPathComponent(filename), options: .atomic)
        } catch {
            AppLogger.data.debug("Cache save failed (\(filename)): \(error)")
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let fileURL = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.makeDecoder().decode(type, from: data)
    }

    // MARK: - Background writes

    /// Encodes and writes `value` off the calling thread. Several calls for
    /// the same file before the queue gets to it collapse into one write of
    /// the latest value.
    func saveInBackground<T: Encodable & Sendable>(_ value: T, filename: String) {
        enqueueWrite(filename: filename, PendingWrite(encode: { try Self.makeEncoder().encode(value) }))
    }

    /// Writes bytes the caller already encoded with `makeEncoder()` (the
    /// `DataStore` comparison pass produces them anyway).
    func writeInBackground(_ data: Data, filename: String) {
        enqueueWrite(filename: filename, PendingWrite(encode: { data }))
    }

    private func enqueueWrite(filename: String, _ write: PendingWrite) {
        let generation = writerState.withLock { state -> UInt64 in
            state.pending[filename] = write
            return state.generation
        }
        let dir = self.dir
        ioQueue.async { [writerState] in
            let job: PendingWrite? = writerState.withLock { state in
                guard state.generation == generation else { return nil }
                return state.pending.removeValue(forKey: filename)
            }
            guard let job else { return }
            do {
                let data = try job.encode()
                try data.write(to: dir.appendingPathComponent(filename), options: .atomic)
            } catch {
                AppLogger.data.debug("Background cache save failed (\(filename)): \(error)")
            }
        }
    }

    /// Blocks until every background write queued so far is on disk. Used
    /// when the app moves to the background and by tests.
    func flushPendingWrites() {
        ioQueue.sync {}
    }

    /// Decodes the whole data cache on the I/O queue — off the main thread,
    /// after any queued writes.
    func loadDataSnapshot() async -> CachedDataSnapshot {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: CachedDataSnapshot(
                    accounts: loadAccounts(),
                    transactions: loadTransactions(),
                    categories: loadCategories(),
                    budgets: loadBudgets(),
                    subscriptions: loadSubscriptions(),
                    profile: loadProfile()
                ))
            }
        }
    }

    // MARK: - Typed helpers

    func saveTransactions(_ items: [Transaction]) { saveInBackground(items, filename: Filename.transactions) }
    func loadTransactions() -> [Transaction]? { load([Transaction].self, filename: Filename.transactions) }

    func saveAccounts(_ items: [Account]) { saveInBackground(items, filename: Filename.accounts) }
    func loadAccounts() -> [Account]? { load([Account].self, filename: Filename.accounts) }

    func saveCategories(_ items: [Category]) { saveInBackground(items, filename: Filename.categories) }
    func loadCategories() -> [Category]? { load([Category].self, filename: Filename.categories) }

    func saveBudgets(_ items: [Budget]) { saveInBackground(items, filename: Filename.budgets) }
    func loadBudgets() -> [Budget]? { load([Budget].self, filename: Filename.budgets) }

    func saveSubscriptions(_ items: [SubscriptionTracker]) { saveInBackground(items, filename: Filename.subscriptions) }
    func loadSubscriptions() -> [SubscriptionTracker]? { load([SubscriptionTracker].self, filename: Filename.subscriptions) }

    func saveProfile(_ item: Profile) { saveInBackground(item, filename: Filename.profile) }
    func loadProfile() -> Profile? { load(Profile.self, filename: Filename.profile) }

    func saveNotes(_ items: [FinancialNote]) { save(items, filename: "notes.json") }
    func loadNotes() -> [FinancialNote]? { load([FinancialNote].self, filename: "notes.json") }

    // Offline queue — synchronous on purpose (see the type comment).
    func savePendingOps(_ ops: [PendingOperation]) { save(ops, filename: "pending_ops.json") }
    func loadPendingOps() -> [PendingOperation]? { load([PendingOperation].self, filename: "pending_ops.json") }

    func saveDeadLetterOps(_ ops: [PendingOperation]) { save(ops, filename: "dead_letter_ops.json") }
    func loadDeadLetterOps() -> [PendingOperation]? { load([PendingOperation].self, filename: "dead_letter_ops.json") }

    /// The user the persisted queue belongs to — a queue must never replay
    /// under someone else's session.
    func saveQueueOwner(_ userId: String?) {
        if let userId {
            save(["userId": userId], filename: "queue_owner.json")
        } else {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("queue_owner.json"))
        }
    }
    func loadQueueOwner() -> String? { load([String: String].self, filename: "queue_owner.json")?["userId"] }

    enum Filename {
        static let transactions = "transactions.json"
        static let accounts = "accounts.json"
        static let categories = "categories.json"
        static let budgets = "budgets.json"
        static let subscriptions = "subscriptions.json"
        static let profile = "profile.json"
    }

    /// Remove cached data. Full wipe on sign-out (queued ops belong to the
    /// signed-out user); `preservingQueue: true` keeps pending/dead-letter
    /// ops across cache-format migrations and forced sign-outs. Background
    /// writes still pending are dropped first and any write in progress is
    /// waited for, so nothing written for the previous user survives.
    func clearAll(preservingQueue: Bool = false) {
        writerState.withLock { state in
            state.generation &+= 1
            state.pending.removeAll()
        }
        ioQueue.sync { [self] in
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
}
