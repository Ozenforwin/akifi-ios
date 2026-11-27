import XCTest
import Supabase
@testable import AkifiIOS

/// The wire shape of `AccountCoverRepository` (migration 20261128100000),
/// captured by a URLProtocol stub behind a real `SupabaseClient`: which
/// endpoint, method, headers and body each call sends — and that no token
/// ever travels in a URL (global rule: secrets only in headers).
final class AccountCoverRepositoryTests: XCTestCase {

    private static let base = URL(string: "https://covers-stub.supabase.test")!
    private static let token = "session-token-for-tests"
    private static let accountId = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"
    private static let path = "\(accountId)/0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e.jpg"

    private var repository: AccountCoverRepository!

    override func setUp() {
        super.setUp()
        CoverStubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverStubProtocol.self]
        let client = SupabaseClient(
            supabaseURL: Self.base,
            supabaseKey: "anon-key-for-tests",
            options: .init(
                auth: .init(storage: MemoryAuthStorage(), autoRefreshToken: false,
                            accessToken: { AccountCoverRepositoryTests.token }),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        repository = AccountCoverRepository(client: client)
    }

    override func tearDown() {
        CoverStubProtocol.reset()
        repository = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func onlyRequest(file: StaticString = #filePath, line: UInt = #line) throws -> CoverStubProtocol.Captured {
        let requests = CoverStubProtocol.captured
        XCTAssertEqual(requests.count, 1, "exactly one request", file: file, line: line)
        return try XCTUnwrap(requests.first, file: file, line: line)
    }

    private func assertNoSecretInURL(_ request: CoverStubProtocol.Captured, file: StaticString = #filePath, line: UInt = #line) {
        let url = request.url.absoluteString
        XCTAssertFalse(url.contains(Self.token), "token in the URL", file: file, line: line)
        XCTAssertFalse(url.lowercased().contains("token="), file: file, line: line)
        XCTAssertFalse(url.contains("/sign/"), "signed URL", file: file, line: line)
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(Self.token)", "the session goes in the header", file: file, line: line)
    }

    // MARK: - Download

    func test_download_isAnAuthenticatedGET_ofThePrivateObject() async throws {
        CoverStubProtocol.respond { _ in (200, ["Content-Type": "image/jpeg"], Data([0xFF, 0xD8, 0xFF])) }

        let data = try await repository.download(path: Self.path)

        XCTAssertEqual(data, Data([0xFF, 0xD8, 0xFF]))
        let request = try onlyRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.path, "/storage/v1/object/account-covers/\(Self.path)")
        XCTAssertNil(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
                     "no query string at all — nothing to leak into access logs")
        assertNoSecretInURL(request)
    }

    // MARK: - Upload

    func test_upload_postsAJPEG_neverOverwrites() async throws {
        CoverStubProtocol.respond { _ in (200, ["Content-Type": "application/json"],
                                          Data(#"{"Key":"account-covers/x","Id":"1"}"#.utf8)) }
        let jpeg = Data("jpeg-bytes".utf8)

        try await repository.upload(jpeg: jpeg, path: Self.path)

        let request = try onlyRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/storage/v1/object/account-covers/\(Self.path)")
        XCTAssertEqual(request.headers["x-upsert"], "false", "a cover name is never reused")
        XCTAssertTrue(request.headers["Content-Type"]?.hasPrefix("multipart/form-data") == true)
        let body = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Type: image/jpeg"), body)
        XCTAssertTrue(body.contains("jpeg-bytes"))
        XCTAssertTrue(body.contains("name=\"cacheControl\"\r\n\r\n0"), "no shared cache keeps a private cover")
        assertNoSecretInURL(request)
    }

    // MARK: - cover_path

    func test_setCoverPath_patchesOnlyTheColumn_andAsksForTheRow() async throws {
        CoverStubProtocol.respond { _ in (200, ["Content-Type": "application/json"],
                                          Data(#"[{"id":"\#(Self.accountId)"}]"#.utf8)) }

        try await repository.setCoverPath(Self.path, accountId: Self.accountId)

        let request = try onlyRequest()
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.url.path, "/rest/v1/accounts")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "id", value: "eq.\(Self.accountId)")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "select", value: "id")))
        XCTAssertTrue(request.headers["Prefer"]?.contains("return=representation") == true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json.keys.sorted(), ["cover_path"], "nothing but the cover is written")
        XCTAssertEqual(json["cover_path"] as? String, Self.path)
        assertNoSecretInURL(request)
    }

    func test_clearCoverPath_sendsAnExplicitNull() async throws {
        CoverStubProtocol.respond { _ in (200, ["Content-Type": "application/json"],
                                          Data(#"[{"id":"\#(Self.accountId)"}]"#.utf8)) }

        try await repository.setCoverPath(nil, accountId: Self.accountId)

        let body = String(decoding: try onlyRequest().body, as: UTF8.self)
        XCTAssertEqual(body, #"{"cover_path":null}"#)
    }

    /// RLS hides the row from a viewer: 200 with no rows is "not allowed",
    /// never "saved".
    func test_setCoverPath_zeroRows_isNotPermitted() async {
        CoverStubProtocol.respond { _ in (200, ["Content-Type": "application/json"], Data("[]".utf8)) }

        do {
            try await repository.setCoverPath(Self.path, accountId: Self.accountId)
            XCTFail("zero updated rows must throw")
        } catch {
            XCTAssertEqual(error as? AccountCoverError, .notPermitted)
        }
    }

    func test_setCoverPath_ownerGuard_surfacesAsPostgrestError() async {
        CoverStubProtocol.respond { _ in (403, ["Content-Type": "application/json"],
                                          Data(#"{"code":"42501","message":"account_cover_owner_only: only the owner of the account can change its cover"}"#.utf8)) }

        do {
            try await repository.setCoverPath(nil, accountId: Self.accountId)
            XCTFail("expected the guard's error")
        } catch {
            XCTAssertEqual((error as? PostgrestError)?.code, "42501")
            XCTAssertEqual(AccountCoverErrorMessage.text(for: error), String(localized: "account.cover.error.ownerOnly"))
        }
    }

    // MARK: - Remove / list

    func test_remove_deletesByPrefixes_skippingAnythingThatIsNotACover() async throws {
        CoverStubProtocol.respond { _ in (200, ["Content-Type": "application/json"], Data("[]".utf8)) }

        try await repository.removeObjects(paths: [Self.path, "../etc/passwd", "\(Self.accountId)/cover.png"])

        let request = try onlyRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.path, "/storage/v1/object/account-covers")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: [String]])
        XCTAssertEqual(json["prefixes"], [Self.path])
    }

    func test_remove_nothingValid_sendsNothing() async throws {
        try await repository.removeObjects(paths: ["nope", ""])
        XCTAssertTrue(CoverStubProtocol.captured.isEmpty)
    }

    func test_list_readsOneBoundedPageOfTheAccountFolder() async throws {
        let other = "1c0d9e8f-7a6b-4c5d-8e3f-2a1b0c9d8e7f.jpg"
        CoverStubProtocol.respond { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"[{"name":"0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e.jpg","id":"11111111-1111-4111-8111-111111111111"},{"name":"\#(other)","id":"22222222-2222-4222-8222-222222222222"},{"name":".emptyFolderPlaceholder","id":"33333333-3333-4333-8333-333333333333"}]"#.utf8))
        }

        let paths = try await repository.listObjects(accountId: Self.accountId.uppercased())

        XCTAssertEqual(paths, [Self.path, "\(Self.accountId)/\(other)"])
        let request = try onlyRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/storage/v1/object/list/account-covers")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["prefix"] as? String, Self.accountId, "the folder is the lower-case account id")
        XCTAssertEqual(json["limit"] as? Int, 100)
    }

    // MARK: - Error text

    func test_errorText_featureNotReady_andOffline() {
        let noColumn = PostgrestError(code: "PGRST204", message: "Could not find the 'cover_path' column of 'accounts' in the schema cache")
        XCTAssertEqual(AccountCoverErrorMessage.text(for: noColumn), String(localized: "server.error.featureNotReady"))
        let noBucket = StorageError(statusCode: "404", message: "Bucket not found", error: "Bucket not found")
        XCTAssertEqual(AccountCoverErrorMessage.text(for: noBucket), String(localized: "server.error.featureNotReady"))
        XCTAssertEqual(AccountCoverErrorMessage.text(for: URLError(.notConnectedToInternet)),
                       String(localized: "account.cover.error.offline"))
        XCTAssertEqual(AccountCoverErrorMessage.text(for: AccountCoverError.notPermitted),
                       String(localized: "account.cover.error.ownerOnly"))
    }
}

// MARK: - Stubs

private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

final class CoverStubProtocol: URLProtocol, @unchecked Sendable {
    struct Captured {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _captured: [Captured] = []
    nonisolated(unsafe) private static var _handler: Handler?

    static var captured: [Captured] { lock.withLock { _captured } }

    static func respond(_ handler: @escaping Handler) {
        lock.withLock { _handler = handler }
    }

    static func reset() {
        lock.withLock {
            _captured = []
            _handler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let captured = Captured(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let handler = Self.lock.withLock { () -> Handler? in
            Self._captured.append(captured)
            return Self._handler
        }
        let (status, headers, data) = handler?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
