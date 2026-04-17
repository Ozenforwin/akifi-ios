import Foundation
import Supabase

final class SupabaseManager: Sendable {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: AppConstants.supabaseURL)!,
            supabaseKey: AppConstants.supabaseAnonKey,
            options: .init(
                auth: .init(autoRefreshToken: true, emitLocalSessionAsInitialSession: true)
            )
        )
    }

    // MARK: - User ID helper
    //
    // Every user-owned table in Supabase has:
    //   - `user_id uuid not null`
    //   - RLS policy `WITH CHECK (auth.uid() = user_id)`
    //
    // Migration 20260413000060 adds `DEFAULT auth.uid()` to every such column,
    // so server-side omitting user_id is now safe (Postgres fills it from the
    // JWT). This helper remains the canonical client-side source of the
    // currently authenticated user id for code that still wants to send it
    // explicitly (e.g. Create*Input DTOs). Always prefer this over reading
    // `dataStore.profile?.id`, which may be stale after sign-in/sign-out.
    //
    // Throws if there is no active session — callers should treat that as a
    // precondition for any write.
    func currentUserId() async throws -> String {
        // Swift's `UUID.uuidString` returns UPPERCASE; Postgres `auth.uid()::text`
        // is lowercase. Storage policies that compare folder names to `auth.uid()::text`
        // (e.g. `(storage.foldername(name))[1] = auth.uid()::text`) fail without
        // this lowercasing — photo uploads were hit by RLS violations (BUG-001).
        try await client.auth.session.user.id.uuidString.lowercased()
    }
}
