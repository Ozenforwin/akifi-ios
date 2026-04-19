import Foundation

/// Thin wrapper around the App Group container that persists a
/// `SharedSnapshot` JSON blob at a fixed path. Written by the main app,
/// read by the widget extension — no other callers.
///
/// Both targets embed the same App Group entitlement
/// `group.ru.akifi.app` so `FileManager.containerURL(...)` resolves to the
/// same on-disk directory.
enum SharedSnapshotStore {
    static let appGroupID = "group.ru.akifi.app"
    private static let fileName = "snapshot.json"

    /// On-disk URL of the snapshot file, or `nil` if entitlements are
    /// missing (e.g. running on the simulator without App Group
    /// provisioning — see README). Widgets fall back to a placeholder in
    /// that case; writes are silently dropped.
    static var snapshotURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        return container.appendingPathComponent(fileName)
    }

    /// Serializes + atomically writes the snapshot. Safe to call from any
    /// actor context.
    static func save(_ snapshot: SharedSnapshot) throws {
        guard let url = snapshotURL else {
            throw SharedSnapshotError.containerUnavailable
        }
        let data = try jsonEncoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Loads the most recent snapshot, or `nil` if the file is missing,
    /// corrupt, or was written by a newer/older schema version the
    /// current code cannot parse.
    static func load() -> SharedSnapshot? {
        guard let url = snapshotURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? jsonDecoder.decode(SharedSnapshot.self, from: data) else {
            return nil
        }
        // Strict version check: any mismatch → treat as stale and let the
        // widget show its "Open app" placeholder instead of garbled data.
        guard snapshot.schemaVersion == SharedSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    /// Deletes the snapshot file. Useful for debugging and logout flows.
    static func clear() {
        guard let url = snapshotURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum SharedSnapshotError: Error {
    case containerUnavailable
}
