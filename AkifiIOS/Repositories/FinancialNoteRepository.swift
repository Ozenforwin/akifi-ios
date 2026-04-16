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

struct UpdateNoteInput: Encodable, Sendable {
    let title: String?
    let content: String?
    let tags: [String]?
    let mood: String?
    let photo_urls: [String]?

    init(title: String? = nil, content: String? = nil, tags: [String]? = nil, mood: String? = nil, photo_urls: [String]? = nil) {
        self.title = title; self.content = content
        self.tags = tags; self.mood = mood; self.photo_urls = photo_urls
    }
}
