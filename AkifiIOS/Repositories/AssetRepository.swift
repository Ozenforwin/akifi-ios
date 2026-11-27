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
        try await SupabasePaging.all("assets") { count in
            supabase
                .from("assets")
                .select(count: count)
                .order("created_at", ascending: false)
        }
    }

    /// Narrow read — fetches assets of a single category. Mostly a
    /// convenience for future drill-down screens; the dashboard
    /// uses `fetchAll` and groups client-side.
    func fetchForCategory(_ category: AssetCategory) async throws -> [Asset] {
        try await SupabasePaging.all("assets") { count in
            supabase
                .from("assets")
                .select(count: count)
                .eq("category", value: category.rawValue)
                .order("created_at", ascending: false)
        }
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

/// Insert payload. `user_id` is optional on the wire: the DB column has
/// `DEFAULT auth.uid()`, so on a missing/empty client-side id we let
/// the server fill it. Sending an empty string would either trip the
/// FK on `auth.users(id)` or get rejected by the RLS policy
/// `assets_own_insert (user_id = auth.uid())`, which is exactly what
/// happens when `SupabaseManager.currentUserId()` returns "" during a
/// brief auth race on app start.
struct CreateAssetInput: Encodable, Sendable {
    let user_id: String?
    let name: String
    let category: String
    let current_value: Int64
    let currency: String
    let icon: String?
    let color: String?
    let notes: String?
    let acquired_date: String?
}

/// Partial update; `notes` / `acquired_date` are double-optional so the
/// form can clear them (`.some(nil)` → NULL) — see `UpdateLiabilityInput`.
struct UpdateAssetInput: Encodable, Sendable {
    let name: String?
    let category: String?
    let current_value: Int64?
    let currency: String?
    let icon: String?
    let color: String?
    let notes: String??
    let acquired_date: String??

    enum CodingKeys: String, CodingKey {
        case name, category, current_value, currency, icon, color, notes, acquired_date
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(current_value, forKey: .current_value)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeNullable(notes, forKey: .notes)
        try c.encodeNullable(acquired_date, forKey: .acquired_date)
    }
}
