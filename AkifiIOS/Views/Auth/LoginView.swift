import SwiftUI
import UIKit
import AuthenticationServices
@preconcurrency import GoogleSignIn

struct LoginView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showMigration = false
    @State private var showEmailAuth = false
    @State private var errorMessage: String?
    @State private var currentNonce: String?
    @State private var isGoogleLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // MARK: - Branding
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(Color.accent.gradient)

                    VStack(spacing: 6) {
                        Text("Akifi")
                            .font(.system(size: 36, weight: .bold, design: .rounded))

                        Text(String(localized: "auth.subtitle"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // MARK: - Features
                VStack(alignment: .leading, spacing: 14) {
                    AuthFeatureRow(icon: "chart.pie.fill", text: String(localized: "auth.feature.analytics"))
                    AuthFeatureRow(icon: "target", text: String(localized: "auth.feature.budgets"))
                    AuthFeatureRow(icon: "sparkles", text: String(localized: "auth.feature.assistant"))
                }
                .padding(.horizontal, 32)

                Spacer()

                // MARK: - Auth Buttons
                VStack(spacing: 12) {
                    // Sign in with Apple
                    SignInWithAppleButton(.signIn) { request in
                        let nonce = String.randomNonce()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = nonce.sha256
                    } onCompletion: { result in
                        Task { await handleAppleSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )

                    // Continue with Google
                    Button {
                        Task { await handleGoogleSignIn() }
                    } label: {
                        HStack(spacing: 8) {
                            Image("GoogleLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            Text(String(localized: "auth.continueGoogle"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                    .disabled(isGoogleLoading)
                    .overlay {
                        if isGoogleLoading {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.ultraThinMaterial)
                            ProgressView()
                        }
                    }

                    // Continue with Email
                    Button {
                        showEmailAuth = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill")
                            Text(String(localized: "auth.continueEmail"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .background(Color.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Telegram migration link
                    Button {
                        showMigration = true
                    } label: {
                        Text(String(localized: "auth.telegramCode"))
                            .font(.subheadline)
                            .foregroundStyle(Color.accent)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)

                // MARK: - Legal links
                HStack(spacing: 4) {
                    Link(String(localized: "auth.privacyPolicy"), destination: URL(string: "https://akifi.pro/privacy")!)
                    Text("&")
                    Link(String(localized: "auth.termsOfService"), destination: URL(string: "https://akifi.pro/terms")!)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $showMigration) {
                MigrationCodeView()
            }
            .sheet(isPresented: $showEmailAuth) {
                EmailAuthView()
            }
            .errorToast($errorMessage)
        }
    }

    // MARK: - Apple Sign In

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = AuthErrorMapper.message(for: NSError(domain: "", code: -1))
                return
            }

            guard let nonce = currentNonce else { return }

            do {
                try await appViewModel.authManager.signInWithApple(idToken: idToken, nonce: nonce)
            } catch {
                print("❌ Apple Sign-In error: \(error)")
                errorMessage = AuthErrorMapper.message(for: error)
            }

        case .failure(let error):
            // Error 1001 = user canceled — silently ignore
            let nsError = error as NSError
            if nsError.code == ASAuthorizationError.canceled.rawValue ||
               nsError.code == ASAuthorizationError.unknown.rawValue {
                return
            }
            errorMessage = AuthErrorMapper.message(for: error)
        }
    }

    // MARK: - Google Sign In

    private func handleGoogleSignIn() async {
        isGoogleLoading = true
        defer { isGoogleLoading = false }

        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }

            let idToken = try await GIDSignInHelper.signIn(presenting: rootVC)
            try await appViewModel.authManager.signInWithGoogle(idToken: idToken)
        } catch let error as GIDSignInError where error.code == .canceled {
            // User canceled — silently ignore
            return
        } catch {
            print("❌ Google Sign-In error: \(error)")
            errorMessage = AuthErrorMapper.message(for: error)
        }
    }
}

// MARK: - Supporting Views

private struct AuthFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accent)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Google Sign In Helper

enum GIDSignInHelper {
    @MainActor
    static func signIn(presenting viewController: UIViewController) async throws -> String {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw NSError(domain: "GIDSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: "No ID token"])
        }
        return idToken
    }
}
