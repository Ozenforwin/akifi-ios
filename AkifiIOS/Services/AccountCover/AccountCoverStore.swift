import CoreGraphics
import Foundation
import Observation
import UIKit

/// Account cover images for every screen: memory + disk cache keyed by the
/// object name, plus the owner's upload / remove flows.
///
/// Object names are immutable (`AccountCoverPath`: a new cover is a new
/// uuid), so a cached image never goes stale — it is simply dropped once no
/// account points at its name any more (`prune`). Offline, the cached image
/// is shown; with nothing cached the card keeps its tinted look — loading a
/// cover never blocks or replaces the card.
@Observable @MainActor
final class AccountCoverStore {
    /// Decoded covers by object name. Observed: a card re-renders when its
    /// image arrives.
    private(set) var images: [String: AccountCoverImage] = [:]
    /// Accounts whose cover is being uploaded or removed right now.
    private(set) var busyAccountIds: Set<String> = []

    /// A failed download is retried after this long (a dangling name, no
    /// network) — not on every render of the carousel.
    static let retryInterval: TimeInterval = 60

    @ObservationIgnored private let remote: any AccountCoverRemote
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var inFlight: [String: Task<Fetched?, Never>] = [:]
    @ObservationIgnored private var failures: [String: Date] = [:]
    /// Bumped by `reset()`: results that arrive for the previous user are
    /// dropped instead of landing in the next user's cache.
    @ObservationIgnored private var generation = 0

    init(
        remote: any AccountCoverRemote = AccountCoverRepository(),
        directory: URL = AccountCoverStore.defaultDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.remote = remote
        self.directory = directory
        self.now = now
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountCovers", isDirectory: true)
    }

    private var originalsDirectory: URL {
        directory.appendingPathComponent("originals", isDirectory: true)
    }

    // MARK: - Reading

    /// The cover in memory, if any — cheap, for `body`. Pair with `load`.
    func image(for path: String?) -> AccountCoverImage? {
        guard let path else { return nil }
        return images[path]
    }

    /// The cover from memory, the disk cache or the server, in that order.
    /// Concurrent calls for one name share a single download. Nil when it
    /// isn't available (offline with nothing cached, a dangling name).
    @discardableResult
    func load(_ path: String?) async -> AccountCoverImage? {
        guard let path, AccountCoverPath.isValid(path) else { return nil }
        if let image = images[path] { return image }

        let task: Task<Fetched?, Never>
        if let running = inFlight[path] {
            task = running
        } else {
            let fileURL = cacheURL(for: path)
            let remote = self.remote
            let mayDownload = failures[path].map { now().timeIntervalSince($0) >= Self.retryInterval } ?? true
            task = Task { await Self.fetch(path: path, fileURL: fileURL, remote: mayDownload ? remote : nil) }
            inFlight[path] = task
        }
        let startGeneration = generation
        let fetched = await task.value
        if inFlight[path] == task { inFlight[path] = nil }
        guard generation == startGeneration else { return nil }

        switch fetched {
        case .some(.cached(let image)):
            images[path] = image
            return image
        case .some(.downloaded(let image, let data)):
            images[path] = image
            failures[path] = nil
            if let url = cacheURL(for: path) { await Self.write(data, to: url) }
            return image
        case .some(.failed):
            failures[path] = now()
            return nil
        case .none:
            return nil
        }
    }

    enum Fetched: Sendable {
        case cached(AccountCoverImage)
        case downloaded(AccountCoverImage, Data)
        case failed
    }

    /// Disk, then (when `remote` is given) the network. Off the main actor.
    nonisolated private static func fetch(path: String, fileURL: URL?, remote: (any AccountCoverRemote)?) async -> Fetched? {
        if let fileURL, let image = await readImage(at: fileURL) {
            return .cached(image)
        }
        guard let remote else { return nil }
        do {
            let data = try await remote.download(path: path)
            guard let image = await decodeImage(data) else { return .failed }
            return .downloaded(image, data)
        } catch {
            return .failed
        }
    }

    // MARK: - Owner flows

    /// Uploads `jpeg` as the new cover of `account`, points the account at
    /// it, then deletes the previous object (best effort). Order matters: a
    /// member never sees a name whose object isn't there yet, and the old
    /// object goes only once nothing points at it. Returns the new name.
    @discardableResult
    func setCover(_ jpeg: Data, for account: Account) async throws -> String {
        busyAccountIds.insert(account.id)
        defer { busyAccountIds.remove(account.id) }

        let path = AccountCoverPath.make(accountId: account.id)
        try await remote.upload(jpeg: jpeg, path: path)
        do {
            try await remote.setCoverPath(path, accountId: account.id)
        } catch {
            // The row still points at the old cover: don't leave the new
            // object behind.
            try? await remote.removeObjects(paths: [path])
            throw error
        }

        // The owner never downloads what they just uploaded.
        if let image = await Self.decodeImage(jpeg) { images[path] = image }
        failures[path] = nil
        if let url = cacheURL(for: path) { await Self.write(jpeg, to: url) }

        if let old = account.coverPath, old != path {
            evict(old)
            try? await remote.removeObjects(paths: [old])
        }
        return path
    }

    /// The owner's «Затемнение» (nil = automatic), shared with every member.
    /// No busy state: the slider's preview already shows the value.
    func setDim(_ dim: Int?, for account: Account) async throws {
        try await remote.setCoverDim(dim, accountId: account.id)
    }

    /// Clears the account's cover, then deletes the object (best effort).
    func removeCover(of account: Account) async throws {
        busyAccountIds.insert(account.id)
        defer { busyAccountIds.remove(account.id) }

        try await remote.setCoverPath(nil, accountId: account.id)
        if let old = account.coverPath {
            evict(old)
            try? await remote.removeObjects(paths: [old])
        }
        removeOriginal(accountId: account.id)
    }

    /// Before the account itself is deleted (only its owner can): every
    /// object in its folder, best effort and bounded — a storage hiccup
    /// never blocks the deletion. Once the row is gone nobody but the
    /// service role could delete them (the policies look up the account).
    /// The row stops pointing at the cover first, so an account whose
    /// deletion then fails is left without a cover, not with a dangling one.
    func purgeObjects(of account: Account, timeout: Double = 8) async {
        let remote = self.remote
        let known = account.coverPath.flatMap { AccountCoverPath.isValid($0) ? $0 : nil }
        let accountId = account.id
        let removed: [String] = (try? await withTimeout(seconds: timeout) {
            if known != nil {
                // Even if this fails the objects still go: a photo must not
                // outlive its account in storage.
                try? await remote.setCoverPath(nil, accountId: accountId)
            }
            var paths = Set(known.map { [$0] } ?? [])
            if let listed = try? await remote.listObjects(accountId: accountId) {
                paths.formUnion(listed)
            }
            guard !paths.isEmpty else { return [String]() }
            try await remote.removeObjects(paths: Array(paths))
            return Array(paths)
        }) ?? known.map { [$0] } ?? []
        removed.forEach(evict)
        removeOriginal(accountId: account.id)
    }

    // MARK: - The original photo («Изменить область»)

    /// The owner's working copy of the photo behind the current cover and
    /// the crop that produced it — kept on this device only (never
    /// uploaded), so «Изменить область» can zoom back out. Metadata-free
    /// (re-encoded by `AccountCoverImageProcessor`).
    struct Original: Codable, Equatable, Sendable {
        let coverPath: String
        let crop: CGRect
    }

    func saveOriginal(_ jpeg: Data, crop: CGRect, coverPath: String) async {
        guard let accountId = AccountCoverPath.accountId(of: coverPath) else { return }
        let sidecar = Original(coverPath: coverPath, crop: crop)
        let directory = originalsDirectory
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? jpeg.write(to: directory.appendingPathComponent("\(accountId).jpg"), options: .atomic)
            if let json = try? JSONEncoder().encode(sidecar) {
                try? json.write(to: directory.appendingPathComponent("\(accountId).json"), options: .atomic)
            }
        }.value
    }

    /// The saved original of `account`'s CURRENT cover (nil when the cover
    /// was set on another device or changed since).
    func original(for account: Account) async -> (jpeg: Data, crop: CGRect)? {
        guard let path = account.coverPath,
              let accountId = AccountCoverPath.accountId(of: path) else { return nil }
        let directory = originalsDirectory
        return await Task.detached(priority: .userInitiated) { () -> (Data, CGRect)? in
            guard let json = try? Data(contentsOf: directory.appendingPathComponent("\(accountId).json")),
                  let sidecar = try? JSONDecoder().decode(Original.self, from: json),
                  sidecar.coverPath == path,
                  let jpeg = try? Data(contentsOf: directory.appendingPathComponent("\(accountId).jpg"))
            else { return nil }
            return (jpeg, sidecar.crop)
        }.value.map { (jpeg: $0.0, crop: $0.1) }
    }

    private func removeOriginal(accountId: String) {
        let id = accountId.lowercased()
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent("\(id).jpg"))
        try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent("\(id).json"))
    }

    // MARK: - Housekeeping

    /// Drops every cached cover no account points at any more (memory and
    /// disk) — replaced covers, removed accounts, a left shared account.
    func prune(keeping paths: Set<String>) async {
        let kept = images.filter { paths.contains($0.key) }
        if kept.count != images.count { images = kept }
        let keepFiles = Set(paths.compactMap(AccountCoverPath.cacheFileName(for:)))
        let keepAccounts = Set(paths.compactMap(AccountCoverPath.accountId(of:)))
        let directory = self.directory
        let originals = originalsDirectory
        await Task.detached(priority: .utility) {
            Self.removeFiles(in: directory, keeping: { keepFiles.contains($0) })
            Self.removeFiles(in: originals, keeping: { name in
                keepAccounts.contains(String(name.split(separator: ".").first ?? ""))
            })
        }.value
    }

    /// Sign-out: nothing of the previous user's covers stays on the device.
    func reset() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        failures = [:]
        images = [:]
        busyAccountIds = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func evict(_ path: String) {
        images[path] = nil
        failures[path] = nil
        if let url = cacheURL(for: path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Disk

    func cacheURL(for path: String) -> URL? {
        AccountCoverPath.cacheFileName(for: path).map { directory.appendingPathComponent($0) }
    }

    nonisolated private static func readImage(at url: URL) async -> AccountCoverImage? {
        await Task.detached(priority: .userInitiated) { () -> AccountCoverImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return AccountCoverImageProcessor.coverImage(from: data)
        }.value
    }

    nonisolated static func decodeImage(_ data: Data) async -> AccountCoverImage? {
        await Task.detached(priority: .userInitiated) { () -> AccountCoverImage? in
            AccountCoverImageProcessor.coverImage(from: data)
        }.value
    }

    nonisolated private static func write(_ data: Data, to url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    nonisolated private static func removeFiles(in directory: URL, keeping keep: (String) -> Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep(name) {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
