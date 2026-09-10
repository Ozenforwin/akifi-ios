import XCTest
@testable import AkifiIOS

/// Pure tests for `SupabasePaging.drain` against a simulated PostgREST.
///
/// The simulator reproduces the one server behaviour that caused the
/// 2026-09-10 shared-balance incident: a response silently capped at
/// `maxRows`, with no error. Every test asserts the same invariant from a
/// different angle — **the assembled set is complete no matter what the
/// server's cap is, what the client asked for, or what changed mid-read.**
final class SupabasePagingTests: XCTestCase {

    // MARK: - Simulated PostgREST

    /// `rows` are the table; `maxRows` is the server's `max-rows`. Mutation
    /// hooks let a test change the table between pages, the way a partner
    /// adding a coffee while you sync would.
    private final class FakeServer {
        var rows: [Int]
        var maxRows: Int
        var ignoresOffset = false
        /// Total the server reports; `nil` mirrors a request without
        /// `count=exact`. Override to make the server lie.
        var reportedTotal: (() -> Int?)?
        var afterPage: ((Int) -> Void)?
        private(set) var requests: [(offset: Int, limit: Int)] = []

        init(rows: [Int], maxRows: Int) {
            self.rows = rows
            self.maxRows = maxRows
        }

        func page(offset: Int, limit: Int, wantTotal: Bool) -> SupabasePaging.Page<Int> {
            requests.append((offset, limit))
            let effectiveOffset = ignoresOffset ? 0 : offset
            let effectiveLimit = min(limit, maxRows)
            let start = min(effectiveOffset, rows.count)
            let end = min(start + effectiveLimit, rows.count)
            let slice = Array(rows[start..<end])
            // An override that returns nil simulates a server with no count.
            let total: Int? = wantTotal ? (reportedTotal.map { $0() } ?? rows.count) : nil
            defer { afterPage?(requests.count) }
            return SupabasePaging.Page(rows: slice, total: total)
        }
    }

    private func drain(
        _ server: FakeServer,
        requestSize: Int = SupabasePaging.requestSize,
        maxPages: Int = SupabasePaging.maxPages,
        dedupe: Bool = true
    ) async throws -> (rows: [Int], report: SupabasePaging.Report) {
        var captured = SupabasePaging.Report()
        let rows = try await SupabasePaging.drain(
            label: "test",
            requestSize: requestSize,
            maxPages: maxPages,
            dedupeKey: dedupe ? { AnyHashable($0) } : nil,
            report: { captured = $0 }
        ) { offset, limit, wantTotal in
            server.page(offset: offset, limit: limit, wantTotal: wantTotal)
        }
        return (rows, captured)
    }

    // MARK: - The incident

    /// 1011 visible rows, server cap 1000 — the exact numbers from the
    /// shared account. The old code returned 1000 and a −38 997 ₽ balance.
    func testServerCap1000_1011Rows_returnsEveryRow() async throws {
        let server = FakeServer(rows: Array(0..<1011), maxRows: 1000)
        let result = try await drain(server)
        XCTAssertEqual(result.rows, Array(0..<1011))
        XCTAssertEqual(result.report.pages, 2, "1000 + 11; the short second page ends the read")
        XCTAssertFalse(result.report.mismatch)
    }

    // MARK: - The server's limit is not our business

    /// The trap the first fix fell into: it stopped on `page.count < 1000`,
    /// so a server capped at 500 would have ended the read after 500 rows —
    /// silently, exactly like the original bug. The driver must not care
    /// what the cap is.
    func testServerCapSmallerThanRequest_returnsEveryRow() async throws {
        let server = FakeServer(rows: Array(0..<1011), maxRows: 500)
        let result = try await drain(server, requestSize: 1000)
        XCTAssertEqual(result.rows, Array(0..<1011))
        XCTAssertEqual(result.report.pages, 3, "500 + 500 + 11")
    }

    /// Cap of 1: pathological, but proves page count is not a correctness
    /// input — only "did we get everything the server said exists".
    func testServerCapOfOne_returnsEveryRow() async throws {
        let server = FakeServer(rows: Array(0..<37), maxRows: 1)
        let result = try await drain(server, requestSize: 1000)
        XCTAssertEqual(result.rows, Array(0..<37))
        XCTAssertEqual(result.report.pages, 37)
    }

    /// Sweep: every combination of client request size and server cap
    /// yields the complete set. `requestSize` is a performance knob only.
    func testRequestSizeIsNotACorrectnessKnob() async throws {
        let table = Array(0..<1234)
        for requestSize in [1, 7, 100, 1000, 5000] {
            for cap in [1, 3, 500, 1000, 100_000] {
                let server = FakeServer(rows: table, maxRows: cap)
                let result = try await drain(server, requestSize: requestSize, maxPages: 10_000)
                XCTAssertEqual(result.rows, table, "requestSize=\(requestSize) cap=\(cap)")
                XCTAssertFalse(result.report.mismatch, "requestSize=\(requestSize) cap=\(cap)")
            }
        }
    }

    // MARK: - Termination edges

    func testExactMultipleOfRequestSize_terminates() async throws {
        let server = FakeServer(rows: Array(0..<2000), maxRows: 1000)
        let result = try await drain(server, requestSize: 1000)
        XCTAssertEqual(result.rows.count, 2000)
        XCTAssertEqual(result.report.pages, 3, "two full pages, then the empty page that proves the end")
    }

    func testEmptyTable() async throws {
        let server = FakeServer(rows: [], maxRows: 1000)
        let result = try await drain(server)
        XCTAssertEqual(result.rows, [])
        XCTAssertEqual(result.report.pages, 1)
    }

    /// Without a server count (e.g. an RPC that cannot report one) a short
    /// page is ambiguous, so the driver must read until an empty page.
    func testNoCountAvailable_readsUntilEmptyPage() async throws {
        let server = FakeServer(rows: Array(0..<1011), maxRows: 500)
        server.reportedTotal = { nil }
        let result = try await drain(server, requestSize: 1000)
        XCTAssertEqual(result.rows, Array(0..<1011))
        XCTAssertEqual(result.report.pages, 4, "500 + 500 + 11 + empty")
        XCTAssertNil(result.report.expectedTotal)
        XCTAssertFalse(result.report.mismatch)
    }

    // MARK: - Data changes mid-read

    /// A row inserted at the front after page 1 shifts every later row by
    /// one, so the last row of page 1 reappears at the top of page 2. The
    /// duplicate is dropped and the original set is still complete.
    func testInsertDuringRead_dedupesAndStaysComplete() async throws {
        let original = Array(0..<1011)
        let server = FakeServer(rows: original, maxRows: 1000)
        server.afterPage = { n in
            if n == 1 { server.rows.insert(-1, at: 0) }
        }
        let result = try await drain(server)
        XCTAssertEqual(Set(result.rows), Set(original))
        XCTAssertEqual(result.rows.count, original.count, "no duplicates")
        XCTAssertEqual(result.report.duplicatesDropped, 1)
        XCTAssertFalse(result.report.mismatch)
        XCTAssertEqual(result.report.attempts, 1)
    }

    /// A row deleted from page 1 after we read it shifts later rows up, so
    /// the first row of page 2 is skipped. The count check catches it and
    /// the retry produces a consistent set.
    func testDeleteDuringRead_retriesOnce() async throws {
        let server = FakeServer(rows: Array(0..<1011), maxRows: 1000)
        var deleted = false
        server.afterPage = { _ in
            if !deleted { deleted = true; server.rows.remove(at: 10) }
        }
        let result = try await drain(server)
        XCTAssertEqual(result.rows, server.rows, "second attempt sees the post-delete table")
        XCTAssertEqual(result.rows.count, 1010)
        XCTAssertEqual(result.report.attempts, 2)
        XCTAssertFalse(result.report.mismatch, "resolved on retry")
    }

    /// Persistent disagreement (the server keeps reporting a total we can
    /// never reach) is reported, not looped on, and the rows we did get are
    /// returned rather than thrown away.
    func testPersistentMismatch_returnsRowsAndFlags() async throws {
        let server = FakeServer(rows: Array(0..<50), maxRows: 1000)
        server.reportedTotal = { 55 }
        let result = try await drain(server)
        XCTAssertEqual(result.rows, Array(0..<50))
        XCTAssertEqual(result.report.attempts, 2)
        XCTAssertTrue(result.report.mismatch)
        XCTAssertEqual(result.report.expectedTotal, 55)
    }

    // MARK: - Broken server

    /// A server that ignores `offset` would feed the same page forever. The
    /// driver notices it has been handed more rows than can exist and fails
    /// loudly instead of returning a bloated or truncated set.
    func testServerIgnoresOffset_throws() async throws {
        let server = FakeServer(rows: Array(0..<2500), maxRows: 1000)
        server.ignoresOffset = true
        do {
            _ = try await drain(server, dedupe: false)
            XCTFail("expected serverIgnoresOffset")
        } catch let error as SupabasePaging.Failure {
            guard case .serverIgnoresOffset = error else {
                return XCTFail("unexpected failure \(error)")
            }
        }
        XCTAssertLessThanOrEqual(server.requests.count, 5, "detected within a few pages, not \(SupabasePaging.maxPages)")
    }

    /// Requests are contiguous and non-overlapping: offset always equals
    /// the number of rows already held, limit is the request size.
    func testRequestsAreContiguous() async throws {
        let server = FakeServer(rows: Array(0..<1011), maxRows: 400)
        _ = try await drain(server, requestSize: 1000)
        XCTAssertEqual(server.requests.map(\.offset), [0, 400, 800])
        XCTAssertTrue(server.requests.allSatisfy { $0.limit == 1000 })
    }
}
