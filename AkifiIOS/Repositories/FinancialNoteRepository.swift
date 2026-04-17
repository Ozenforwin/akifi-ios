import Foundation
import Supabase

final class FinancialNoteRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll(limit: Int = 50, offset: Int = 0, noteType: NoteType? = nil) async throws -> [FinancialNote] {
        var query = supabase
            .from("financial_notes")
            .select()

        if let noteType {
            query = query.eq("note_type", value: noteType.rawValue)
        }

        return try await query
            .order("created_at", ascending: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }

    func fetchByTransaction(transactionId: String) async throws -> [FinancialNote] {
        try await supabase
            .from("financial_notes")
            .select()
            .eq("transaction_id", value: transactionId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func search(query: String) async throws -> [FinancialNote] {
        try await supabase
            .from("financial_notes")
            .select()
            .or("title.ilike.%\(query)%,content.ilike.%\(query)%")
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .value
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
        let rows: [TagRow] = try await supabase
            .from("financial_notes")
            .select("tags")
            .execute()
            .value
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
    let mood: String?
    let photo_urls: [String]?
    let period_start: String??
    let period_end: String??

    init(
        title: String? = nil,
        content: String? = nil,
        transaction_id: String?? = nil,
        tags: [String]? = nil,
        mood: String? = nil,
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
        try c.encodeIfPresent(mood, forKey: .mood)
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
