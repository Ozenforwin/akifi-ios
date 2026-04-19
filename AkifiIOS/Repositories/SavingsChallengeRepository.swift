import Foundation
import Supabase

final class SavingsChallengeRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll(status: ChallengeStatus? = nil) async throws -> [SavingsChallenge] {
        var query = supabase.from("savings_challenges").select()
        if let status {
            query = query.eq("status", value: status.rawValue)
        }
        return try await query
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchActive() async throws -> [SavingsChallenge] {
        try await fetchAll(status: .active)
    }

    func fetchCompleted() async throws -> [SavingsChallenge] {
        try await fetchAll(status: .completed)
    }

    func create(_ input: CreateChallengeInput) async throws -> SavingsChallenge {
        try await supabase
            .from("savings_challenges")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateChallengeInput) async throws {
        try await supabase
            .from("savings_challenges")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func updateProgress(id: String, amount: Int64) async throws {
        // Encode as whole units so the DB keeps numeric semantics consistent
        // with how we encode `progress_amount` in `SavingsChallenge.encode`.
        struct Payload: Encodable { let progress_amount: Double }
        let body = Payload(progress_amount: Double(amount) / 100.0)
        try await supabase
            .from("savings_challenges")
            .update(body)
            .eq("id", value: id)
            .execute()
    }

    func updateStatus(id: String, status: ChallengeStatus) async throws {
        struct Payload: Encodable { let status: String }
        try await supabase
            .from("savings_challenges")
            .update(Payload(status: status.rawValue))
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("savings_challenges")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

/// DTO for creating a challenge. Kopecks/minor-units are encoded as whole
/// currency units (same pattern as Transaction.encode).
struct CreateChallengeInput: Encodable, Sendable {
    let user_id: String
    let type: String
    let title: String
    let description: String?
    let target_amount: Double?
    let duration_days: Int
    let start_date: String
    let end_date: String
    let status: String
    let progress_amount: Double
    let category_id: String?
    let linked_goal_id: String?
}

struct UpdateChallengeInput: Encodable, Sendable {
    let title: String?
    let description: String?
    let target_amount: Double?
    let status: String?
    let category_id: String?
    let linked_goal_id: String?
}
