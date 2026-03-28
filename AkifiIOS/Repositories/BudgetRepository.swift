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
    let user_id: String
    let name: String?
    let description: String?
    let amount: Decimal
    let period_type: String
    let category_ids: [String]
    let account_ids: [String]?
    let rollover_enabled: Bool
    let alert_thresholds: [Int]
    let budget_type: String
    let custom_start_date: String?
    let custom_end_date: String?
}

struct UpdateBudgetInput: Encodable, Sendable {
    var name: String?
    var description: String?
    var amount: Decimal?
    var period_type: String?
    var category_ids: [String]?
    var account_ids: [String]?
    var rollover_enabled: Bool?
    var alert_thresholds: [Int]?
    var budget_type: String?
    var custom_start_date: String?
    var custom_end_date: String?
}
