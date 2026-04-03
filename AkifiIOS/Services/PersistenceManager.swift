import Foundation
import os

/// JSON file-based offline cache for app data.
/// Stores data in Library/Caches/OfflineData/ — survives app restarts,
/// may be purged by system under storage pressure (which is fine, it's a cache).
final class PersistenceManager: Sendable {
    static let shared = PersistenceManager()

    private let dir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = caches.appendingPathComponent("OfflineData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    /// Remove all cached data (e.g. on sign-out)
    func clearAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
