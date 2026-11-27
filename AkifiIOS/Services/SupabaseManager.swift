import Foundation
import Supabase

/// Serializes concurrent session refreshes.
///
/// Supabase refresh tokens are single-use: if two callers race on
/// `supabase.auth.refreshSession()`, the first one consumes the refresh
/// token, the second one gets `refresh_token_already_used`. That second
/// error has historically been misclassified as "session expired" and
/// shown to the user even though their session is actually healthy.
///
/// This actor guarantees at most one in-flight refresh; concurrent
/// callers await the same Task. Also provides a short cooldown so a
/// burst of callers (scenePhase→active plus an immediate user tap)
/// doesn't force a second refresh.
actor SessionCoordinator {
    private var ongoing: Task<Void, Error>?
    private var lastSuccessfulRefresh: Date = .distantPast
    private let cooldown: TimeInterval = 30

    func refresh(client: SupabaseClient, force: Bool = false) async throws {
        if !force, Date().timeIntervalSince(lastSuccessfulRefresh) < cooldown {
            return
        }

        if let task = ongoing {
            try await task.value
            return
        }

        let task = Task<Void, Error> {
            _ = try await client.auth.refreshSession()
        }
        ongoing = task

        do {
            try await task.value
            lastSuccessfulRefresh = Date()
            ongoing = nil
        } catch {
            ongoing = nil
            throw error
        }
    }

    /// Block until any in-flight refresh completes; no-op if nothing pending.
    /// Use before reading `supabase.auth.session` on a hot path that may race
    /// with a scenePhase refresh task.
    func waitForPendingRefresh() async {
        if let task = ongoing {
            _ = try? await task.value
        }
    }
}

final class SupabaseManager: Sendable {
    static let shared = SupabaseManager()

    let client: SupabaseClient
    let sessionCoordinator = SessionCoordinator()

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: AppConstants.supabaseURL)!,
            supabaseKey: AppConstants.supabaseAnonKey,
            options: .init(
                auth: .init(autoRefreshToken: true, emitLocalSessionAsInitialSession: true)
            )
        )
    }

    /// Deduplicated refresh. Safe to call concurrently from any actor/task.
    /// Second concurrent caller awaits the first caller's Task instead of
    /// triggering a second HTTP request (which would fail with
    /// `refresh_token_already_used`).
    func refreshSession(force: Bool = false) async throws {
        try await sessionCoordinator.refresh(client: client, force: force)
    }

    /// Returns the current session, waiting for any in-flight refresh first.
    /// Prevents reading a stale access token while a refresh is racing.
    func currentSession() async throws -> Session {
        await sessionCoordinator.waitForPendingRefresh()
        return try await client.auth.session
    }

    /// A session whose access token is valid right now, refreshing it first
    /// when it has expired — or nil.
    ///
    /// The SDK never fails a request for a missing session: when there is
    /// none (signed out, refresh failed offline, refresh token revoked) it
    /// silently sends the **anon key** instead. Under RLS that turns every
    /// read into `[]` and every UPDATE/DELETE into a zero-row "success".
    /// Callers that cache what they read or replay queued writes must check
    /// this first and treat nil as offline.
    func validSession(timeout seconds: Double = 10) async -> Session? {
        await sessionCoordinator.waitForPendingRefresh()
        let client = self.client
        guard let session = try? await withTimeout(seconds: seconds, operation: {
            try await client.auth.session
        }) else { return nil }
        return session.isExpired ? nil : session
    }

    func hasValidSession() async -> Bool {
        await validSession() != nil
    }

    /// Lowercased id of the user behind a valid session, or nil.
    func validSessionUserId() async -> String? {
        await validSession()?.user.id.uuidString.lowercased()
    }

    /// Cheap synchronous check that a session object still exists locally —
    /// used after a long fetch to detect a sign-out / failed refresh that
    /// happened mid-flight (later requests then went out as anon).
    var hasLocalSession: Bool {
        client.auth.currentSession != nil
    }

    /// A local session whose access token has not run out yet (no safety
    /// margin) — after a fetch, "the requests went out authenticated".
    var hasUnexpiredLocalSession: Bool {
        guard let session = client.auth.currentSession else { return false }
        return Date(timeIntervalSince1970: session.expiresAt) > Date()
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
