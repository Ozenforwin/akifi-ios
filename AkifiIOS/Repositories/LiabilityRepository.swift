import Foundation
import Supabase

/// CRUD wrapper around the `liabilities` table. RLS enforces own-only
/// access server-side (see
/// `supabase/migrations/20260419150100_liabilities.sql`).
///
/// All monetary values use BIGINT kopecks — no ×100 scaling. Same
/// convention as `AssetRepository`.
final class LiabilityRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Returns every liability the current user owns, newest-first.
    func fetchAll() async throws -> [Liability] {
        try await supabase
            .from("liabilities")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Narrow read — fetches liabilities of a single category.
    func fetchForCategory(_ category: LiabilityCategory) async throws -> [Liability] {
        try await supabase
            .from("liabilities")
            .select()
            .eq("category", value: category.rawValue)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func create(_ input: CreateLiabilityInput) async throws -> Liability {
        try await supabase
            .from("liabilities")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateLiabilityInput) async throws {
        try await supabase
            .from("liabilities")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("liabilities")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

struct CreateLiabilityInput: Encodable, Sendable {
    let user_id: String
    let name: String
    let category: String
    let current_balance: Int64
    let original_amount: Int64?
    let interest_rate: Double?
    let currency: String
    let icon: String?
    let color: String?
    let notes: String?
    let monthly_payment: Int64?
    let end_date: String?
}

struct UpdateLiabilityInput: Encodable, Sendable {
    let name: String?
    let category: String?
    let current_balance: Int64?
    let original_amount: Int64?
    let interest_rate: Double?
    let currency: String?
    let icon: String?
    let color: String?
    let notes: String?
    let monthly_payment: Int64?
    let end_date: String?
}
