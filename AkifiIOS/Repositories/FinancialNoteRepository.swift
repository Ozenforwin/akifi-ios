import Foundation
import Supabase

final class FinancialNoteRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Position in the journal feed: the last note of the previous page.
    struct PageCursor: Sendable, Equatable {
        let createdAt: String
        let id: String
    }

    /// Infinite-scroll window — `JournalViewModel` pages through the feed
    /// itself, so a bounded slice is the contract here, not a bug.
    /// One page of the feed, newest first, ordered by `(created_at, id)`.
    /// Keyset paging: the next page starts strictly after `cursor`, so a
    /// note created or deleted between pages can't shift the window the
    /// way `OFFSET` did (one note duplicated or skipped per change).
    func fetchPage(limit: Int = 50, after cursor: PageCursor?) async throws -> [FinancialNote] {
        var query = supabase
            .from("financial_notes")
            .select()
        if let cursor {
            // Quoted values: timestamps contain ':' '.' '+', reserved in
            // PostgREST's logic-tree syntax.
            let ts = Self.quoted(cursor.createdAt)
            let id = Self.quoted(cursor.id)
            query = query.or("created_at.lt.\(ts),and(created_at.eq.\(ts),id.lt.\(id))")
        }
        return try await query
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func fetchByTransaction(transactionId: String) async throws -> [FinancialNote] {
        try await SupabasePaging.all("financial_notes") { count in
            supabase
                .from("financial_notes")
                .select(count: count)
                .eq("transaction_id", value: transactionId)
                .order("created_at", ascending: false)
        }
    }

    /// Every note whose title or body contains `query` (case-insensitive),
    /// newest first — the complete set (ADR-003), not the first 50.
    func search(query: String) async throws -> [FinancialNote] {
        let pattern = Self.ilikeContainsValue(query)
        return try await SupabasePaging.all("financial_notes") { count in
            supabase
                .from("financial_notes")
                .select(count: count)
                .or("title.ilike.\(pattern),content.ilike.\(pattern)")
                .order("created_at", ascending: false)
        }
    }

    /// The value of an `ilike` "contains" filter inside PostgREST's `or=(…)`
    /// syntax, for text the user typed (V6). Unescaped, a comma or a
    /// parenthesis in the query split or broke the logic tree; `%` / `_`
    /// were wildcards; PostgREST turns `*` into `%`.
    /// - LIKE metacharacters `\`, `%`, `_` are escaped with `\`; `*` becomes
    ///   `_` (any one character — PostgREST offers no literal `*`).
    /// - The whole pattern is double-quoted, with `\` and `"` escaped,
    ///   the same quoting as the keyset cursor above.
    static func ilikeContainsValue(_ query: String) -> String {
        var like = ""
        for ch in query {
            switch ch {
            case "\\", "%", "_": like += "\\" + String(ch)
            case "*": like += "_"
            default: like.append(ch)
            }
        }
        return quoted("%" + like + "%")
    }

    func create(_ input: CreateNoteInput) async throws -> FinancialNote {
        try await supabase
            .from("financial_notes")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateNoteInput) async throws {
        try await supabase
            .from("financial_notes")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("financial_notes")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func fetchAllTags() async throws -> [String] {
        struct TagRow: Decodable { let tags: [String]? }
        let rows: [TagRow] = try await SupabasePaging.all("financial_notes") { count in
            supabase
                .from("financial_notes")
                .select("tags", count: count)
        }
        var allTags: Set<String> = []
        for row in rows {
            if let tags = row.tags { allTags.formUnion(tags) }
        }
        return allTags.sorted()
    }
}

struct CreateNoteInput: Encodable, Sendable {
    /// Optional client-generated UUID (lowercase). When present, the note row is
    /// created with this id so pre-uploaded photo paths can reference it.
    let id: String?
    let user_id: String
    let title: String?
    let content: String
    let transaction_id: String?
    let tags: [String]?
    let mood: String?
    let photo_urls: [String]?
    let note_type: String
    let period_start: String?
    let period_end: String?
}

/// Partial update payload. Fields left as `nil` are omitted from the JSON so
/// existing DB values are preserved. `transaction_id`, `period_start` and
/// `period_end` use double-optional so callers can explicitly clear them by
/// passing `.some(nil)` (encoded as JSON `null`).
struct UpdateNoteInput: Encodable, Sendable {
    let title: String?
    let content: String?
    let transaction_id: String??
    let tags: [String]?
    /// Double-optional like `transaction_id`: a mood the user deselected is
    /// written as NULL instead of being dropped from the payload (V4).
    let mood: String??
    let photo_urls: [String]?
    let period_start: String??
    let period_end: String??

    init(
        title: String? = nil,
        content: String? = nil,
        transaction_id: String?? = nil,
        tags: [String]? = nil,
        mood: String?? = nil,
        photo_urls: [String]? = nil,
        period_start: String?? = nil,
        period_end: String?? = nil
    ) {
        self.title = title
        self.content = content
        self.transaction_id = transaction_id
        self.tags = tags
        self.mood = mood
        self.photo_urls = photo_urls
        self.period_start = period_start
        self.period_end = period_end
    }

    enum CodingKeys: String, CodingKey {
        case title, content
        case transaction_id
        case tags, mood
        case photo_urls
        case period_start
        case period_end
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeNullable(mood, forKey: .mood)
        try c.encodeIfPresent(photo_urls, forKey: .photo_urls)
        // Double-optional: .none = omit, .some(nil) = encode JSON null, .some(x) = encode x
        if let tx = transaction_id {
            if let tx { try c.encode(tx, forKey: .transaction_id) }
            else { try c.encodeNil(forKey: .transaction_id) }
        }
        if let ps = period_start {
            if let ps { try c.encode(ps, forKey: .period_start) }
            else { try c.encodeNil(forKey: .period_start) }
        }
        if let pe = period_end {
            if let pe { try c.encode(pe, forKey: .period_end) }
            else { try c.encodeNil(forKey: .period_end) }
        }
    }
}
