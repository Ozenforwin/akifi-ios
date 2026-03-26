import Foundation
import Supabase

final class SavingsGoalRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [SavingsGoal] {
        try await supabase
            .from("savings_goals")
            .select()
            .order("priority", ascending: true)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func create(_ input: CreateSavingsGoalInput) async throws -> SavingsGoal {
        try await supabase
            .from("savings_goals")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateSavingsGoalInput) async throws {
        try await supabase
            .from("savings_goals")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("savings_goals")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func fetchContributions(goalId: String) async throws -> [SavingsContribution] {
        try await supabase
            .from("savings_contributions")
            .select()
            .eq("goal_id", value: goalId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func addContribution(_ input: CreateContributionInput) async throws -> SavingsContribution {
        try await supabase
            .from("savings_contributions")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }
}

struct CreateSavingsGoalInput: Encodable, Sendable {
    let name: String
    let icon: String
    let color: String
    let target_amount: Int64
    let deadline: String?
    let account_id: String?
    let reminder_enabled: Bool
    let priority: Int
}

struct UpdateSavingsGoalInput: Encodable, Sendable {
    let name: String?
    let target_amount: Int64?
    let current_amount: Int64?
    let status: String?
    let deadline: String?
}

struct CreateContributionInput: Encodable, Sendable {
    let goal_id: String
    let amount: Int64
    let type: String
    let note: String?
}
