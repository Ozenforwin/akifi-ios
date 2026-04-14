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
        try await SupabaseManager.shared.currentUserId()
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

struct CreateTransactionInput: Codable, Sendable {
    let user_id: String
    let account_id: String?
    let amount: Decimal
    let currency: String?
    let type: String
    let date: String
    let description: String?
    let category_id: String?
    let merchant_name: String?
    let transfer_group_id: String?

    init(user_id: String, account_id: String?, amount: Decimal, currency: String?, type: String, date: String, description: String?, category_id: String?, merchant_name: String?, transfer_group_id: String? = nil) {
        self.user_id = user_id; self.account_id = account_id; self.amount = amount
        self.currency = currency; self.type = type; self.date = date
        self.description = description; self.category_id = category_id
        self.merchant_name = merchant_name; self.transfer_group_id = transfer_group_id
    }
}

struct UpdateTransactionInput: Codable, Sendable {
    let amount: Decimal?
    let currency: String?
    let type: String?
    let date: String?
    let description: String?
    let category_id: String?
    let merchant_name: String?
    let account_id: String?

    init(amount: Decimal? = nil, currency: String? = nil, type: String? = nil, date: String? = nil, description: String? = nil, category_id: String? = nil, merchant_name: String? = nil, account_id: String? = nil) {
        self.amount = amount; self.currency = currency; self.type = type
        self.date = date; self.description = description
        self.category_id = category_id; self.merchant_name = merchant_name
        self.account_id = account_id
    }
}
