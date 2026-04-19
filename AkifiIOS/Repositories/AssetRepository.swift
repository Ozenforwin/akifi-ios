import Foundation
import Supabase

/// CRUD wrapper around the `assets` table. RLS enforces own-only access
/// server-side (see `supabase/migrations/20260419150000_assets.sql`), so
/// reads don't need a client-side user-id filter.
///
/// All monetary values are sent as BIGINT kopecks — no client-side scaling.
/// This differs from `AccountRepository` (which divides by 100 on write)
/// because the `assets.current_value` column already stores minor units.
final class AssetRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Returns every asset the current user owns, newest-first (stable for
    /// list display). RLS filters implicitly.
    func fetchAll() async throws -> [Asset] {
        try await supabase
            .from("assets")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Narrow read — fetches assets of a single category. Mostly a
    /// convenience for future drill-down screens; the dashboard
    /// uses `fetchAll` and groups client-side.
    func fetchForCategory(_ category: AssetCategory) async throws -> [Asset] {
        try await supabase
            .from("assets")
            .select()
            .eq("category", value: category.rawValue)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func create(_ input: CreateAssetInput) async throws -> Asset {
        try await supabase
            .from("assets")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateAssetInput) async throws {
        try await supabase
            .from("assets")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("assets")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

/// Insert payload. `user_id` is filled from `auth.uid()` client-side via
/// `SupabaseManager.currentUserId()` — the DB also defaults it to `auth.uid()`
/// (belt-and-suspenders).
struct CreateAssetInput: Encodable, Sendable {
    let user_id: String
    let name: String
    let category: String
    let current_value: Int64
    let currency: String
    let icon: String?
    let color: String?
    let notes: String?
    let acquired_date: String?
}

struct UpdateAssetInput: Encodable, Sendable {
    let name: String?
    let category: String?
    let current_value: Int64?
    let currency: String?
    let icon: String?
    let color: String?
    let notes: String?
    let acquired_date: String?
}
