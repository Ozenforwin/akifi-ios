import Foundation
import Supabase

final class BudgetRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Budget] {
        try await supabase
            .from("budgets")
            .select()
            .eq("is_active", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func create(_ input: CreateBudgetInput) async throws -> Budget {
        try await supabase
            .from("budgets")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateBudgetInput) async throws {
        try await supabase
            .from("budgets")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("budgets")
            .update(["is_active": false])
            .eq("id", value: id)
            .execute()
    }
}

struct CreateBudgetInput: Encodable, Sendable {
    let name: String
    let amount: Int64
    let billing_period: String
    let categories: [String]?
    let account_id: String?
    let rollover_enabled: Bool
    let alert_threshold: Double?
}

struct UpdateBudgetInput: Encodable, Sendable {
    let name: String?
    let amount: Int64?
    let billing_period: String?
    let categories: [String]?
    let rollover_enabled: Bool?
    let alert_threshold: Double?
}
