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
        try await SupabasePaging.all("liabilities") { count in
            supabase
                .from("liabilities")
                .select(count: count)
                .order("created_at", ascending: false)
        }
    }

    /// Narrow read — fetches liabilities of a single category.
    func fetchForCategory(_ category: LiabilityCategory) async throws -> [Liability] {
        try await SupabasePaging.all("liabilities") { count in
            supabase
                .from("liabilities")
                .select(count: count)
                .eq("category", value: category.rawValue)
                .order("created_at", ascending: false)
        }
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

/// Partial update. Single-optional fields: nil = leave the column alone.
/// The nullable columns the form can CLEAR are double-optional (V4): `.none`
/// leaves them alone, `.some(nil)` writes NULL. A synthesized Encodable
/// drops nil keys, so an end date, rate, payment or note the user removed
/// stayed on the server. (Same contract as `UpdateNoteInput`.)
struct UpdateLiabilityInput: Encodable, Sendable {
    let name: String?
    let category: String?
    let current_balance: Int64?
    let original_amount: Int64??
    let interest_rate: Double??
    let currency: String?
    let icon: String?
    let color: String?
    let notes: String??
    let monthly_payment: Int64??
    let end_date: String??

    enum CodingKeys: String, CodingKey {
        case name, category, current_balance, original_amount, interest_rate
        case currency, icon, color, notes, monthly_payment, end_date
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(current_balance, forKey: .current_balance)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeNullable(original_amount, forKey: .original_amount)
        try c.encodeNullable(interest_rate, forKey: .interest_rate)
        try c.encodeNullable(notes, forKey: .notes)
        try c.encodeNullable(monthly_payment, forKey: .monthly_payment)
        try c.encodeNullable(end_date, forKey: .end_date)
    }
}
