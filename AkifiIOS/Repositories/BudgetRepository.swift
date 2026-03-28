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
    let amount: Decimal
    let period_type: String
    let category_ids: [String]?
    let account_ids: [String]?
    let rollover_enabled: Bool
    let alert_thresholds: [Int]?
    let budget_type: String?
    let custom_start_date: String?
    let custom_end_date: String?

    init(amount: Decimal, period_type: String, category_ids: [String]?, account_ids: [String]?, rollover_enabled: Bool, alert_thresholds: [Int]?, budget_type: String?, custom_start_date: String? = nil, custom_end_date: String? = nil) {
        self.amount = amount
        self.period_type = period_type
        self.category_ids = category_ids
        self.account_ids = account_ids
        self.rollover_enabled = rollover_enabled
        self.alert_thresholds = alert_thresholds
        self.budget_type = budget_type
        self.custom_start_date = custom_start_date
        self.custom_end_date = custom_end_date
    }
}

struct UpdateBudgetInput: Encodable, Sendable {
    let amount: Decimal?
    let period_type: String?
    let category_ids: [String]?
    let account_ids: [String]?
    let rollover_enabled: Bool?
    let alert_thresholds: [Int]?
    let budget_type: String?
    let custom_start_date: String?
    let custom_end_date: String?

    init(amount: Decimal? = nil, period_type: String? = nil, category_ids: [String]? = nil, account_ids: [String]? = nil, rollover_enabled: Bool? = nil, alert_thresholds: [Int]? = nil, budget_type: String? = nil, custom_start_date: String? = nil, custom_end_date: String? = nil) {
        self.amount = amount
        self.period_type = period_type
        self.category_ids = category_ids
        self.account_ids = account_ids
        self.rollover_enabled = rollover_enabled
        self.alert_thresholds = alert_thresholds
        self.budget_type = budget_type
        self.custom_start_date = custom_start_date
        self.custom_end_date = custom_end_date
    }
}
