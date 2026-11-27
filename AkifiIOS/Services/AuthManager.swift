import Foundation
import Supabase
import AuthenticationServices

@Observable @MainActor
final class AuthManager {
    var isAuthenticated = false
    var currentUser: User?
    var isLoading = true

    /// The session ended without the user asking (dead refresh token, the
    /// SDK dropped it). `LoginView` says so — and that unsynced entries
    /// wait for the same account to sign back in. Cleared on sign-in.
    private(set) var sessionEndedUnexpectedly = false

    private let supabase = SupabaseManager.shared.client

    /// Called after the session ended without the user asking (refresh
    /// token revoked / expired) — `AppViewModel` wipes the previous user's
    /// local state. An explicit sign-out goes through `AppViewModel.signOut()`.
    @ObservationIgnored var onSessionEnded: (@MainActor () -> Void)?

    /// Whether the SDK still holds a session (keychain). Seam for tests.
    @ObservationIgnored var sdkHasSession: @MainActor () -> Bool = {
        SupabaseManager.shared.client.auth.currentSession != nil
    }
    @ObservationIgnored private var authEventsTask: Task<Void, Never>?

    // MARK: - SDK auth events (Y1)

    /// supabase-swift ends a session on its own: a refresh answered with
    /// `refresh_token_already_used` / `refresh_token_not_found` /
    /// `session_not_found` makes it delete the keychain session, emit
    /// `.signedOut` and throw `AuthError.sessionMissing`. Nobody listened,
    /// so the app stayed "signed in" with no session: every load silently
    /// did nothing and every write queued forever. Listen, and route an
    /// unrequested sign-out into `onSessionEnded` (sign-in screen, owner-
    /// tagged offline queue kept for the same user's return).
    func startObservingAuthEvents() {
        guard authEventsTask == nil else { return }
        let client = supabase
        authEventsTask = Task { @MainActor [weak self] in
            for await change in client.auth.authStateChanges {
                guard let self else { return }
                self.handleAuthEvent(change.event, session: change.session)
            }
        }
    }

    /// Entry point for one SDK auth event (the test seam: inject events).
    func handleAuthEvent(_ event: AuthChangeEvent, session: Session?) {
        if Self.isForcedSignOut(
            event: event,
            isAuthenticated: isAuthenticated,
            explicitSignOutInProgress: explicitSignOutInProgress,
            sdkHasSession: sdkHasSession()
        ) {
            AppLogger.auth.warning("SDK ended the session (\(event.rawValue, privacy: .public)) — signing out locally")
            endSessionUnexpectedly()
            return
        }
        switch event {
        case .tokenRefreshed, .userUpdated:
            if isAuthenticated, let user = session?.user, user.id == currentUser?.id {
                currentUser = user
            }
        default:
            break
        }
    }

    /// Pure routing rule: an SDK sign-out the user didn't ask for, while
    /// the UI is signed in and the SDK really has no session left (a quick
    /// re-sign-in may already have stored a new one).
    nonisolated static func isForcedSignOut(
        event: AuthChangeEvent,
        isAuthenticated: Bool,
        explicitSignOutInProgress: Bool,
        sdkHasSession: Bool
    ) -> Bool {
        guard event == .signedOut || event == .userDeleted else { return false }
        return isAuthenticated && !explicitSignOutInProgress && !sdkHasSession
    }

    /// The session is gone for good — whichever path noticed first (auth
    /// event, `sessionMissing` on refresh, a load finding no session).
    /// Idempotent.
    func endSessionUnexpectedly() {
        guard isAuthenticated, !explicitSignOutInProgress else { return }
        isAuthenticated = false
        currentUser = nil
        sessionEndedUnexpectedly = true
        onSessionEnded?()
    }

    /// A load or write found no session object at all while online: the
    /// SDK dropped it and its event was missed (or never came).
    func sessionVanished() {
        guard !sdkHasSession() else { return }
        endSessionUnexpectedly()
    }

    private func didSignIn(_ user: User) {
        currentUser = user
        isAuthenticated = true
        sessionEndedUnexpectedly = false
    }

    /// Network half of sign-out (revoke the refresh token). Seam for tests.
    @ObservationIgnored var revokeRemoteSession: @MainActor () async throws -> Void = {
        let client = SupabaseManager.shared.client
        try await withTimeout(seconds: 6) { try await client.auth.signOut() }
    }
    /// Local half: make sure no session survives in the keychain. Seam for tests.
    @ObservationIgnored var removeLocalSession: @MainActor () async -> Void = {
        let client = SupabaseManager.shared.client
        guard client.auth.currentSession != nil else { return }
        // `signOut(scope: .local)` drops the stored session before it even
        // tries the network, so the bounded wait is only for the request.
        _ = try? await withTimeout(seconds: 3) { try await client.auth.signOut(scope: .local) }
    }

    // MARK: - Password Reset

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }

    // MARK: - Google Sign In

    func signInWithGoogle(idToken: String) async throws {
        let session = try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .google, idToken: idToken)
        )
        didSignIn(session.user)
        AnalyticsService.logSignIn(method: "google")
    }

    func checkSession() async {
        // Fast local path — no network round-trip on the splash screen.
        // A keychain session with a still-valid access token is enough to
        // start; offline we accept even an expired one (the refresh can
        // only fail without a network, and the next foreground refresh
        // fixes the token once connectivity returns). Without this, an
        // airplane-mode cold start ate the full 5 s timeout below.
        await NetworkMonitor.shared.waitForFirstUpdate()
        if let local = supabase.auth.currentSession,
           !local.isExpired || !NetworkMonitor.shared.isConnected {
            currentUser = local.user
            isAuthenticated = true
            isLoading = false
            return
        }

        do {
            // Capture supabase locally so the @Sendable closure inside
            // withTimeout does not capture @MainActor-isolated self.
            let client = self.supabase
            let session = try await withTimeout(seconds: 5) {
                try await client.auth.session
            }
            currentUser = session.user
            isAuthenticated = true
        } catch {
            // `auth.session` refreshes when the access token is expired —
            // offline that refresh can only fail. If the keychain still
            // holds a session and the error isn't a definitive revocation,
            // treat the user as authenticated: cached data renders, and the
            // next foreground refresh fixes the token once network returns.
            if !Self.isDefinitivelyExpired(error),
               let localSession = supabase.auth.currentSession {
                AppLogger.auth.info("Session check failed transiently, using local session (offline start)")
                currentUser = localSession.user
                isAuthenticated = true
            } else {
                isAuthenticated = false
                currentUser = nil
                // There was a session and it is dead: say why the sign-in
                // screen is back.
                if Self.isDefinitivelyExpired(error) { sessionEndedUnexpectedly = true }
            }
        }
        isLoading = false
    }

    /// Last-resort resolve when `checkSession()` blew through the splash
    /// deadline (hung SDK call on an offline cold start): trust the keychain
    /// session if one exists and unblock the UI. No-op once resolved.
    func forceResolveFromLocalSession() {
        guard isLoading else { return }
        if let local = supabase.auth.currentSession {
            currentUser = local.user
            isAuthenticated = true
        } else {
            isAuthenticated = false
            currentUser = nil
        }
        isLoading = false
    }

    /// Force-refresh the access token. Call on app foreground to avoid stale
    /// tokens after long background suspension. Silent no-op if no session.
    ///
    /// Goes through `SupabaseManager.sessionCoordinator` so concurrent callers
    /// (e.g. an AI request racing with scenePhase.active) don't both try to
    /// consume the same single-use refresh token.
    func refreshSessionIfNeeded() async {
        guard isAuthenticated else { return }
        // The SDK may have dropped the session while the app was suspended
        // (its event can't be observed then): nothing to refresh, sign in.
        guard sdkHasSession() else {
            endSessionUnexpectedly()
            return
        }
        do {
            try await withTimeout(seconds: 10) {
                try await SupabaseManager.shared.refreshSession()
            }
            if let session = try? await supabase.auth.session {
                currentUser = session.user
            }
            AppLogger.auth.info("Session refreshed successfully")
        } catch {
            AppLogger.auth.error("Session refresh failed: \(error.localizedDescription)")
            // Only sign out on a definitively invalid refresh token.
            // Transient errors (network, race conditions, server hiccups) must
            // NOT log the user out — they'd see the generic "session expired"
            // screen while their session is actually still valid.
            if Self.isDefinitivelyExpired(error) {
                AppLogger.auth.warning("Refresh token invalid — signing out")
                await removeLocalSession()
                endSessionUnexpectedly()
            }
        }
    }

    /// True only for errors that mean the refresh token is actually dead and
    /// re-login is unavoidable. Excludes network errors, race conditions,
    /// and 5xx server errors.
    ///
    /// supabase-swift reports a dead refresh token as `.sessionMissing`
    /// (it has already deleted the session — Y1), not as the GoTrue code
    /// the string match below looks for.
    nonisolated static func isDefinitivelyExpired(_ error: Error) -> Bool {
        if let authError = error as? AuthError {
            switch authError {
            case .sessionMissing:
                return true
            case .api(_, let code, _, _):
                if definitiveAuthErrorCodes.contains(code.rawValue) { return true }
            default:
                break
            }
        }
        let description = "\(error)".lowercased()
        // Supabase GoTrue error codes that signal terminal state:
        return description.contains("refresh_token_not_found")
            || description.contains("invalid_grant")
            || description.contains("invalid_refresh_token")
            || description.contains("user_not_found")
    }

    /// GoTrue codes after which the session cannot come back.
    nonisolated static let definitiveAuthErrorCodes: Set<String> = [
        "refresh_token_not_found", "refresh_token_already_used",
        "session_not_found", "session_expired", "user_not_found", "user_banned",
    ]

    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        didSignIn(session.user)
        AnalyticsService.logSignIn(method: "apple")
    }

    func signInWithEmail(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        didSignIn(session.user)
        AnalyticsService.logSignIn(method: "email")
    }

    func signUpWithEmail(email: String, password: String) async throws {
        let session = try await supabase.auth.signUp(email: email, password: password)
        if let session = session.session {
            didSignIn(session.user)
            AnalyticsService.logSignUp(method: "email")
        }
    }

    func migrateWithCode(_ code: String) async throws {
        struct MigrateResponse: Decodable {
            let accessToken: String
            let refreshToken: String

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
            }
        }

        let response: MigrateResponse = try await supabase.functions.invoke(
            "ios-migrate-auth",
            options: .init(body: ["code": code])
        )

        try await supabase.auth.setSession(accessToken: response.accessToken, refreshToken: response.refreshToken)
        let session = try await supabase.auth.session
        didSignIn(session.user)
        AnalyticsService.logSignIn(method: "migration")
    }

    /// Runs an explicit sign-out flow (sign-out, account deletion): the
    /// `.signedOut` the SDK emits meanwhile is the user's own request.
    func withExplicitSignOut<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        explicitSignOutDepth += 1
        defer { explicitSignOutDepth -= 1 }
        return try await body()
    }

    /// While an explicit sign-out / account deletion runs, the `.signedOut`
    /// it makes the SDK emit is the user's own, not a forced one.
    @ObservationIgnored private var explicitSignOutDepth = 0
    private var explicitSignOutInProgress: Bool { explicitSignOutDepth > 0 }

    /// Ends the session on this device. Never fails: the network revoke is
    /// best effort (offline it can only fail), the local session is always
    /// removed. Throwing here used to leave the UI "signed in" with no
    /// session behind it — the SDK had already dropped the keychain session
    /// before the request failed. The UI leaves the signed-in state first;
    /// local data is wiped by the caller BEFORE this runs
    /// (`AppViewModel.signOut()` → `resetForSignOut()`, Y3).
    func signOut() async {
        await withExplicitSignOut {
            currentUser = nil
            isAuthenticated = false
            sessionEndedUnexpectedly = false
            do {
                try await revokeRemoteSession()
            } catch {
                AppLogger.auth.warning("Remote sign-out failed, signing out locally: \(error.localizedDescription)")
            }
            await removeLocalSession()
        }
    }

    /// Deletes the account server-side and clears device preferences. The
    /// caller (`AppViewModel.deleteAccount()`) then signs out and wipes
    /// local data; on failure nothing local changes and the error surfaces.
    func deleteAccount() async throws {
        // Call edge function to delete all user data and auth record
        let client = supabase
        try await withExplicitSignOut {
            try await client.functions.invoke(
                "delete-account",
                options: .init(body: ["confirm": true])
            )
        }
        UserDefaults.standard.removeObject(forKey: "onboarding_completed")
        UserDefaults.standard.removeObject(forKey: "selected_currency")
        UserDefaults.standard.removeObject(forKey: "data_currency")
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        UserDefaults.standard.removeObject(forKey: "categoryLayout")
        UserDefaults.standard.removeObject(forKey: "hapticEnabled")
    }
}
