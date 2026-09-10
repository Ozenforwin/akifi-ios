import Foundation
import Supabase

/// Complete-set reads from PostgREST.
///
/// PostgREST silently caps every response at the project's `max-rows`
/// setting (1000 on Supabase by default). It does not error, it does not
/// warn — it returns the first N rows of the ordered result plus a
/// `Content-Range` header nobody reads. A repository doing
/// `.select().execute().value` therefore gets a *complete-looking* array
/// that is missing its tail the moment a user crosses that threshold.
///
/// For most tables the tail is "old rows nobody scrolls to". For
/// `transactions` it is the foundation of every account balance
/// (`initial_balance + Σ` over the whole history), so a missing tail does
/// not hide data — it corrupts the number on the home screen. That is what
/// happened on 2026-09-10: one member of a shared account crossed 1000
/// visible rows (RLS unions own rows with every shared account's rows),
/// lost the 11 oldest, and saw −38 997 ₽ where +36 539 ₽ was correct.
///
/// What this type guarantees:
///
/// 1. **The server's limit is never assumed.** `requestSize` is a
///    round-trip hint, not a contract. Termination is driven by what the
///    server actually returns — advance by `page.count`, stop only when the
///    data is exhausted. Lower `max-rows` to 500 or raise it to 10 000 and
///    the result is still complete, with no rebuild and no App Store
///    release. A client-side constant must never decide correctness.
/// 2. **A total order is enforced.** Offset paging over a non-unique sort
///    lets Postgres reshuffle ties between requests, so a row can land on
///    two pages or on none. The primary key is appended as the final
///    `order` term of every query.
/// 3. **The result is cross-checked and self-healing.** The first page
///    asks for `count: .exact`. If the assembled rows do not match what
///    the server said exists (rows inserted/deleted mid-read), the read is
///    retried once; a persistent mismatch is logged and reported to
///    analytics so we hear about drift before a user does.
///
/// Every list read in the app goes through here. `Scripts/lint-unbounded-fetch.py`
/// fails CI otherwise.
enum SupabasePaging {

    /// Rows requested per round-trip. A performance knob only — see rule 1.
    static let requestSize = 1000

    /// Absolute ceiling on round-trips per attempt, so a server that ignores
    /// `offset` cannot spin us forever. Not a data limit: the loop normally
    /// stops long before this, and a hit is reported as an error, never as
    /// a silently truncated result.
    static let maxPages = 1_000

    struct Page<Row: Sendable>: Sendable {
        let rows: [Row]
        /// Server-reported total for the whole query (`Content-Range` tail).
        /// `nil` when the request did not ask for a count.
        let total: Int?

        init(rows: [Row], total: Int? = nil) {
            self.rows = rows
            self.total = total
        }
    }

    enum Failure: Error, Equatable {
        /// The server kept returning rows past its own reported total, or
        /// past `maxPages` — it is not honouring `offset`.
        case serverIgnoresOffset(label: String, pages: Int)
    }

    /// Diagnostics for one complete read. Consumed by tests; production
    /// callers ignore it.
    struct Report: Sendable, Equatable {
        var pages = 0
        var attempts = 0
        var expectedTotal: Int?
        var duplicatesDropped = 0
        var mismatch = false
    }

    // MARK: - Pure driver

    /// Assembles the full result set by repeatedly calling `fetchPage`.
    ///
    /// Knows nothing about the network beyond the closure, which is what
    /// makes it unit-testable against a simulated PostgREST with any
    /// `max-rows` value, concurrent edits, or a broken `offset`.
    ///
    /// - `fetchPage(offset, limit, wantTotal)` returns the rows at
    ///   `[offset, offset + limit)` in the query's order. `wantTotal` is
    ///   `true` on the first page only; that is where `Page.total` is read.
    /// - `dedupeKey` removes rows that straddled a page boundary because
    ///   the dataset shifted mid-read. Pass the primary key.
    static func drain<Row: Sendable>(
        label: String,
        requestSize: Int = requestSize,
        maxPages: Int = maxPages,
        dedupeKey: ((Row) -> AnyHashable)? = nil,
        report: ((Report) -> Void)? = nil,
        fetchPage: (_ offset: Int, _ limit: Int, _ wantTotal: Bool) async throws -> Page<Row>
    ) async throws -> [Row] {
        precondition(requestSize > 0, "requestSize must be positive")
        var diagnostics = Report()
        var rows: [Row] = []

        // Two attempts: the second only runs when the first assembled a set
        // that disagrees with the server's own count, i.e. the data moved
        // under us. One retry is enough in practice; a second mismatch is
        // reported rather than looped on.
        attempts: for attempt in 1...2 {
            diagnostics.attempts = attempt
            rows = []
            var offset = 0
            var expectedTotal: Int?
            var pages = 0

            while true {
                let page = try await fetchPage(offset, requestSize, offset == 0)
                pages += 1
                diagnostics.pages += 1
                if offset == 0 { expectedTotal = page.total }
                rows += page.rows

                // Exhausted: nothing more, full stop.
                if page.rows.isEmpty { break }

                offset += page.rows.count

                // A short page is ambiguous: end of data, OR the server's
                // max-rows is smaller than what we asked for. The count
                // disambiguates — only stop early when we already hold
                // everything the server said exists. Without a count, the
                // only trustworthy signal is an empty page.
                if page.rows.count < requestSize,
                   let expectedTotal, rows.count >= expectedTotal {
                    break
                }

                // Runaway protection — not a data limit (see `maxPages`).
                let pastTotal = expectedTotal.map { offset > $0 + requestSize } ?? false
                if pastTotal || pages >= maxPages {
                    throw Failure.serverIgnoresOffset(label: label, pages: pages)
                }
            }

            if let dedupeKey {
                var seen = Set<AnyHashable>()
                seen.reserveCapacity(rows.count)
                let before = rows.count
                rows = rows.filter { seen.insert(dedupeKey($0)).inserted }
                diagnostics.duplicatesDropped += before - rows.count
            }

            diagnostics.expectedTotal = expectedTotal
            guard let expectedTotal, expectedTotal != rows.count else {
                diagnostics.mismatch = false
                break attempts
            }

            diagnostics.mismatch = true
            if attempt == 1 {
                AppLogger.data.warning(
                    "\(label, privacy: .public): assembled \(rows.count) rows, server reported \(expectedTotal) — data changed mid-read, retrying"
                )
            } else {
                AppLogger.data.error(
                    "\(label, privacy: .public): assembled \(rows.count) rows, server reported \(expectedTotal) after retry — returning what we have"
                )
                AnalyticsService.logEvent("fetch_integrity_mismatch", params: [
                    "table": label,
                    "assembled": rows.count,
                    "expected": expectedTotal,
                ])
            }
        }

        report?(diagnostics)
        return rows
    }

    // MARK: - PostgREST adapter

    /// Complete read of a PostgREST list query.
    ///
    /// `query` builds the request and is invoked once per page — builders
    /// are mutable and `order` accumulates, so a fresh one per request is
    /// the safe choice. It is `@Sendable` because callers on `@MainActor`
    /// (view models, views) hand it to this nonisolated function; capture
    /// only Sendable values (the client, ids, enums). Pass the `count` argument straight into
    /// `.select(count:)` (or `.rpc(count:)`): it is `.exact` on the first
    /// page only.
    ///
    /// `tiebreak` is the primary key, appended after the caller's own
    /// `order` terms to make the sort total. Composite keys pass every
    /// column, e.g. `["user_id", "account_id"]`.
    static func all<Row: Decodable & Sendable>(
        _ label: String,
        tiebreak: [String] = ["id"],
        key: (@Sendable (Row) -> AnyHashable)? = nil,
        query: @Sendable (_ count: CountOption?) throws -> PostgrestTransformBuilder
    ) async throws -> [Row] {
        try await drain(label: label, dedupeKey: key) { offset, limit, wantTotal in
            var builder = try query(wantTotal ? .exact : nil)
            for column in tiebreak {
                builder = builder.order(column)
            }
            let response: PostgrestResponse<[Row]> = try await builder
                .range(from: offset, to: offset + limit - 1)
                .execute()
            return Page(rows: response.value, total: response.count)
        }
    }

    /// `all` for rows with a primary key: boundary duplicates caused by a
    /// concurrent insert are dropped by `id` before the cross-check.
    static func all<Row: Decodable & Sendable & Identifiable>(
        _ label: String,
        tiebreak: [String] = ["id"],
        query: @Sendable (_ count: CountOption?) throws -> PostgrestTransformBuilder
    ) async throws -> [Row] {
        try await all(label, tiebreak: tiebreak, key: { AnyHashable($0.id) }, query: query)
    }
}
