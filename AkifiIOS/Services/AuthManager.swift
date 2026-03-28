import Foundation
import Supabase
import AuthenticationServices

@Observable @MainActor
final class AuthManager {
    var isAuthenticated = false
    var currentUser: User?
    var isLoading = true

    private let supabase = SupabaseManager.shared.client

    func checkSession() async {
        do {
            let session = try await supabase.auth.session
            currentUser = session.user
            isAuthenticated = true
        } catch {
            isAuthenticated = false
            currentUser = nil
        }
        isLoading = false
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        currentUser = session.user
        isAuthenticated = true
    }

    func signInWithEmail(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        currentUser = session.user
        isAuthenticated = true
    }

    func signUpWithEmail(email: String, password: String) async throws {
        let session = try await supabase.auth.signUp(email: email, password: password)
        if let session = session.session {
            currentUser = session.user
            isAuthenticated = true
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
        currentUser = session.user
        isAuthenticated = true
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        currentUser = nil
        isAuthenticated = false
    }

    func deleteAccount() async throws {
        // Call edge function to delete all user data and auth record
        try await supabase.functions.invoke(
            "delete-account",
            options: .init(body: ["confirm": true])
        )
        // Clear local state
        UserDefaults.standard.removeObject(forKey: "onboarding_completed")
        UserDefaults.standard.removeObject(forKey: "selected_currency")
        UserDefaults.standard.removeObject(forKey: "data_currency")
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        UserDefaults.standard.removeObject(forKey: "categoryLayout")
        UserDefaults.standard.removeObject(forKey: "hapticEnabled")
        currentUser = nil
        isAuthenticated = false
    }
}
