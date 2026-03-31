import Foundation
import Supabase

final class TransactionRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll(accountId: String? = nil, from: String? = nil, to: String? = nil) async throws -> [Transaction] {
        var query = supabase
            .from("transactions")
            .select()

        if let accountId {
            query = query.eq("account_id", value: accountId)
        }
        if let from {
            query = query.gte("date", value: from)
        }
        if let to {
            query = query.lte("date", value: to)
        }

        return try await query
            .order("date", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func currentUserId() async throws -> String {
        try await supabase.auth.session.user.id.uuidString
    }

    func create(_ input: CreateTransactionInput) async throws -> Transaction {
        try await supabase
            .from("transactions")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateTransactionInput) async throws {
        try await supabase
            .from("transactions")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("transactions")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

struct CreateTransactionInput: Encodable, Sendable {
    let user_id: String
    let account_id: String?
    let amount: Decimal
    let currency: String?
    let type: String
    let date: String
    let description: String?
    let category_id: String?
    let merchant_name: String?
}

struct UpdateTransactionInput: Encodable, Sendable {
    let amount: Decimal?
    let currency: String?
    let type: String?
    let date: String?
    let description: String?
    let category_id: String?
    let merchant_name: String?
}
