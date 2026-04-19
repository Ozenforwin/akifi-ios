import Foundation
import Supabase

/// CRUD wrapper around the `net_worth_snapshots` table. One row per user
/// per day (UNIQUE(user_id, snapshot_date)). `upsertToday` is the canonical
/// write path — it's safe to call multiple times per day, the second call
/// overwrites the first.
///
/// RLS is own-only (see `supabase/migrations/20260419150200_net_worth_snapshots.sql`).
final class NetWorthSnapshotRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Returns up to `limit` snapshots for the current user, newest first.
    /// Used to drive the history chart. 365 rows ≈ 1 year of daily points;
    /// server index `idx_net_worth_snapshots_user_date` keeps this cheap.
    func fetchForUser(limit: Int = 365) async throws -> [NetWorthSnapshot] {
        try await supabase
            .from("net_worth_snapshots")
            .select()
            .order("snapshot_date", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Inserts or updates today's snapshot. Uses the UNIQUE(user_id,
    /// snapshot_date) composite as the conflict target. `user_id` is sent
    /// explicitly so the upsert can match existing rows (DB default
    /// `auth.uid()` alone doesn't help here — we need the value in the
    /// conflict key).
    func upsertToday(
        accountsTotal: Int64,
        assetsTotal: Int64,
        liabilitiesTotal: Int64,
        netWorth: Int64,
        currency: String
    ) async throws -> NetWorthSnapshot {
        let userId = try await SupabaseManager.shared.currentUserId()
        let today = Self.dateFormatter.string(from: Date())

        struct Payload: Encodable {
            let user_id: String
            let snapshot_date: String
            let accounts_total: Int64
            let assets_total: Int64
            let liabilities_total: Int64
            let net_worth: Int64
            let currency: String
        }

        let payload = Payload(
            user_id: userId,
            snapshot_date: today,
            accounts_total: accountsTotal,
            assets_total: assetsTotal,
            liabilities_total: liabilitiesTotal,
            net_worth: netWorth,
            currency: currency
        )

        return try await supabase
            .from("net_worth_snapshots")
            .upsert(payload, onConflict: "user_id,snapshot_date")
            .select()
            .single()
            .execute()
            .value
    }

    /// UTC-stable "yyyy-MM-dd" formatter. Shared so the upsert key format
    /// matches whatever the calculator used when deciding "have I captured
    /// today yet?".
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
