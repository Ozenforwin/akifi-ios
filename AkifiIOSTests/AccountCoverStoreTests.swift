import XCTest
@testable import AkifiIOS

/// `AccountCoverStore`: the memory + disk cache keyed by the (immutable)
/// object name, and the order of the owner's writes.
@MainActor
final class AccountCoverStoreTests: XCTestCase {

    private static let accountId = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"

    private var directory: URL!
    private var remote: FakeCoverRemote!
    private var clock: Date!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoverStore-\(UUID().uuidString)", isDirectory: true)
        remote = FakeCoverRemote()
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeStore() -> AccountCoverStore {
        AccountCoverStore(remote: remote, directory: directory, now: { [unowned self] in self.clock })
    }

    private func account(cover: String?) -> Account {
        Account(id: Self.accountId, userId: "owner", name: "Отпуск", icon: "🏖️", color: "#38BDF8",
                initialBalance: 0, coverPath: cover)
    }

    private static func jpeg(red: CGFloat = 0.2) -> Data {
        let context = CGContext(data: nil, width: 38, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 38, height: 20))
        return AccountCoverImageProcessor.jpeg(context.makeImage()!)!
    }

    private var newPath: String { AccountCoverPath.make(accountId: Self.accountId) }

    // MARK: - Cache: miss / hit

    func test_miss_downloadsOnce_thenMemoryHit() async {
        let path = newPath
        await remote.setObject(Self.jpeg(), at: path)
        let store = makeStore()

        XCTAssertNil(store.image(for: path), "nothing before load")
        let first = await store.load(path)
        XCTAssertNotNil(first)
        XCTAssertNotNil(store.image(for: path))
        let second = await store.load(path)
        XCTAssertNotNil(second)

        let downloads = await remote.downloads
        XCTAssertEqual(downloads, [path], "the second load is a memory hit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cacheURL(for: path)!.path), "written to disk")
    }

    func test_diskHit_survivesARelaunch_withoutTheNetwork() async {
        let path = newPath
        await remote.setObject(Self.jpeg(), at: path)
        _ = await makeStore().load(path)

        await remote.setOffline(true)
        let relaunched = makeStore()
        let image = await relaunched.load(path)
        XCTAssertNotNil(image, "offline, the cached cover still shows")
        let downloads = await remote.downloads
        XCTAssertEqual(downloads.count, 1, "no second download")
    }

    func test_concurrentLoads_shareOneDownload() async {
        let path = newPath
        await remote.setObject(Self.jpeg(), at: path)
        await remote.setDelay(0.2)
        let store = makeStore()

        async let a = store.load(path)
        async let b = store.load(path)
        async let c = store.load(path)
        let results = await [a, b, c]
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        let downloads = await remote.downloads
        XCTAssertEqual(downloads.count, 1)
    }

    func test_failure_isNotRetriedOnEveryRender_butAfterTheInterval() async {
        let path = newPath
        let store = makeStore()
        await remote.setOffline(true)

        let failed = await store.load(path)
        XCTAssertNil(failed)
        _ = await store.load(path)
        var downloads = await remote.downloads
        XCTAssertEqual(downloads.count, 1, "the carousel re-rendering doesn't hammer the server")

        await remote.setOffline(false)
        await remote.setObject(Self.jpeg(), at: path)
        clock = clock.addingTimeInterval(AccountCoverStore.retryInterval + 1)
        let retried = await store.load(path)
        XCTAssertNotNil(retried)
        downloads = await remote.downloads
        XCTAssertEqual(downloads.count, 2)
    }

    func test_invalidNames_areNeverFetched() async {
        let store = makeStore()
        let none = await store.load(nil)
        XCTAssertNil(none)
        let traversal = await store.load("../../secret.jpg")
        XCTAssertNil(traversal)
        let downloads = await remote.downloads
        XCTAssertTrue(downloads.isEmpty)
    }

    // MARK: - Replace

    func test_setCover_uploadsThenPointsThenDeletesTheOld_andCachesTheNew() async throws {
        let old = newPath
        await remote.setObject(Self.jpeg(red: 0.9), at: old)
        let store = makeStore()
        _ = await store.load(old)
        let oldFile = store.cacheURL(for: old)!
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))

        let path = try await store.setCover(Self.jpeg(), for: account(cover: old))

        XCTAssertTrue(AccountCoverPath.isValid(path, accountId: Self.accountId))
        XCTAssertNotEqual(path, old, "a new cover is a new name")
        let calls = await remote.calls
        XCTAssertEqual(calls, [
            .download(old),
            .upload(path),
            .setCoverPath(path, Self.accountId),
            .remove([old]),
        ], "the row points at the new object only after it exists; the old one goes last")
        XCTAssertNotNil(store.image(for: path), "the owner never downloads what they uploaded")
        XCTAssertNil(store.image(for: old), "replaced cover dropped from memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "… and from disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cacheURL(for: path)!.path))
        XCTAssertTrue(store.busyAccountIds.isEmpty)
    }

    func test_setCover_rowUpdateFails_removesTheNewObject_keepsTheOld() async {
        let old = newPath
        await remote.setObject(Self.jpeg(), at: old)
        await remote.failSetCoverPath(AccountCoverError.notPermitted)
        let store = makeStore()
        _ = await store.load(old)

        do {
            _ = try await store.setCover(Self.jpeg(), for: account(cover: old))
            XCTFail("expected the row update to fail")
        } catch {
            XCTAssertEqual(error as? AccountCoverError, .notPermitted)
        }
        let calls = await remote.calls
        guard case .upload(let uploaded) = calls[1] else { return XCTFail("upload first: \(calls)") }
        XCTAssertEqual(calls.last, .remove([uploaded]), "no orphan of the failed attempt")
        XCTAssertFalse(calls.contains(.remove([old])), "the current cover stays")
        XCTAssertNotNil(store.image(for: old))
    }

    func test_setCover_uploadFails_changesNothing() async {
        await remote.failUpload(URLError(.notConnectedToInternet))
        let store = makeStore()
        do {
            _ = try await store.setCover(Self.jpeg(), for: account(cover: nil))
            XCTFail("expected the upload to fail")
        } catch {
            XCTAssertEqual(AccountCoverErrorMessage.text(for: error), String(localized: "account.cover.error.offline"))
        }
        let calls = await remote.calls
        XCTAssertEqual(calls.count, 1, "no row update after a failed upload")
    }

    // MARK: - Remove / purge

    func test_removeCover_clearsTheRowThenDeletesTheObject() async throws {
        let old = newPath
        await remote.setObject(Self.jpeg(), at: old)
        let store = makeStore()
        _ = await store.load(old)

        try await store.removeCover(of: account(cover: old))

        let calls = await remote.calls
        XCTAssertEqual(Array(calls.suffix(2)), [.setCoverPath(nil, Self.accountId), .remove([old])])
        XCTAssertNil(store.image(for: old))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cacheURL(for: old)!.path))
    }

    func test_purge_beforeAccountDeletion_removesTheWholeFolder() async {
        let current = newPath
        let leftover = newPath
        await remote.setObject(Self.jpeg(), at: current)
        await remote.setObject(Self.jpeg(), at: leftover)
        let store = makeStore()

        await store.purgeObjects(of: account(cover: current))

        let calls = await remote.calls
        XCTAssertEqual(calls.first, .setCoverPath(nil, Self.accountId))
        XCTAssertTrue(calls.contains(.list(Self.accountId)))
        guard case .remove(let removed) = calls.last else { return XCTFail("\(calls)") }
        XCTAssertEqual(Set(removed), [current, leftover], "the current cover and a leftover of a failed delete")
    }

    func test_purge_isBounded_andNeverThrows() async {
        await remote.setDelay(5)
        let store = makeStore()
        let started = Date()
        await store.purgeObjects(of: account(cover: newPath), timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a hanging server can't block deleting the account")
    }

    // MARK: - Housekeeping

    func test_prune_keepsOnlyCoversAnAccountPointsAt() async {
        let kept = newPath
        let dropped = newPath
        await remote.setObject(Self.jpeg(), at: kept)
        await remote.setObject(Self.jpeg(), at: dropped)
        let store = makeStore()
        _ = await store.load(kept)
        _ = await store.load(dropped)

        await store.prune(keeping: [kept])

        XCTAssertNotNil(store.image(for: kept))
        XCTAssertNil(store.image(for: dropped))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cacheURL(for: kept)!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cacheURL(for: dropped)!.path))
    }

    func test_reset_signOut_leavesNothingOnTheDevice() async {
        let path = newPath
        await remote.setObject(Self.jpeg(), at: path)
        let store = makeStore()
        _ = await store.load(path)

        store.reset()

        XCTAssertNil(store.image(for: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_reset_dropsALateResultOfThePreviousUser() async {
        let path = newPath
        await remote.setObject(Self.jpeg(), at: path)
        await remote.setDelay(0.3)
        let store = makeStore()

        async let late = store.load(path)
        try? await Task.sleep(for: .milliseconds(50))
        store.reset()
        let result = await late
        XCTAssertNil(result)
        XCTAssertNil(store.image(for: path), "the next user's cache stays empty")
    }

    func test_original_isOnlyOfferedForTheCoverItProduced() async throws {
        let path = newPath
        let store = makeStore()
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        await store.saveOriginal(Self.jpeg(), crop: crop, coverPath: path)

        let original = await store.original(for: account(cover: path))
        XCTAssertEqual(original?.crop, crop)
        XCTAssertNotNil(original?.jpeg)
        let afterChange = await store.original(for: account(cover: newPath))
        XCTAssertNil(afterChange, "the cover was changed elsewhere: the saved photo is stale")
        let noCover = await store.original(for: account(cover: nil))
        XCTAssertNil(noCover)
    }
}

// MARK: - Fake remote

actor FakeCoverRemote: AccountCoverRemote {
    enum Call: Equatable {
        case download(String)
        case upload(String)
        case setCoverPath(String?, String)
        case setCoverDim(Int?, String)
        case remove([String])
        case list(String)
    }

    private(set) var calls: [Call] = []
    private var objects: [String: Data] = [:]
    private var offline = false
    private var delay: Double = 0
    private var setCoverPathError: Error?
    private var uploadError: Error?

    var downloads: [String] {
        calls.compactMap { if case .download(let p) = $0 { p } else { nil } }
    }

    func setObject(_ data: Data, at path: String) { objects[path] = data }
    func setOffline(_ value: Bool) { offline = value }
    func setDelay(_ seconds: Double) { delay = seconds }
    func failSetCoverPath(_ error: Error) { setCoverPathError = error }
    func failUpload(_ error: Error) { uploadError = error }

    private func wait() async throws {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if offline { throw URLError(.notConnectedToInternet) }
    }

    func download(path: String) async throws -> Data {
        calls.append(.download(path))
        try await wait()
        guard let data = objects[path] else { throw StorageErrorStub.notFound }
        return data
    }

    func upload(jpeg: Data, path: String) async throws {
        calls.append(.upload(path))
        try await wait()
        if let uploadError { throw uploadError }
        objects[path] = jpeg
    }

    func setCoverPath(_ path: String?, accountId: String) async throws {
        calls.append(.setCoverPath(path, accountId))
        try await wait()
        if let setCoverPathError { throw setCoverPathError }
    }

    func setCoverDim(_ dim: Int?, accountId: String) async throws {
        calls.append(.setCoverDim(dim, accountId))
        try await wait()
        if let setCoverPathError { throw setCoverPathError }
    }

    func removeObjects(paths: [String]) async throws {
        calls.append(.remove(paths))
        try await wait()
        paths.forEach { objects[$0] = nil }
    }

    func listObjects(accountId: String) async throws -> [String] {
        calls.append(.list(accountId))
        try await wait()
        return objects.keys.filter { $0.hasPrefix(accountId + "/") }.sorted()
    }

    enum StorageErrorStub: Error { case notFound }
}
