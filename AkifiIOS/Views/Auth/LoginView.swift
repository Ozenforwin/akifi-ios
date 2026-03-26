import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showMigration = false
    @State private var showEmailLogin = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Logo
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)

                    Text("Akifi")
                        .font(.largeTitle.bold())

                    Text("Личные финансы")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Auth buttons
                VStack(spacing: 16) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        Task { await handleAppleSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 50)

                    Button {
                        showEmailLogin = true
                    } label: {
                        HStack {
                            Image(systemName: "envelope.fill")
                            Text("Войти с Email")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        showMigration = true
                    } label: {
                        Text("У меня есть код из Telegram")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom)
                }
            }
            .sheet(isPresented: $showMigration) {
                MigrationCodeView()
            }
            .sheet(isPresented: $showEmailLogin) {
                EmailLoginView()
            }
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Не удалось получить токен Apple"
                return
            }

            do {
                try await appViewModel.authManager.signInWithApple(idToken: idToken, nonce: "")
            } catch {
                errorMessage = error.localizedDescription
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

struct EmailLoginView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SecureField("Пароль", text: $password)
                    .textContentType(isSignUp ? .newPassword : .password)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await authenticate() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text(isSignUp ? "Зарегистрироваться" : "Войти")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(isLoading || email.isEmpty || password.isEmpty)

                Button {
                    isSignUp.toggle()
                } label: {
                    Text(isSignUp ? "Уже есть аккаунт? Войти" : "Нет аккаунта? Зарегистрироваться")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }
            .padding(24)
            .navigationTitle(isSignUp ? "Регистрация" : "Вход")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func authenticate() async {
        isLoading = true
        errorMessage = nil

        do {
            if isSignUp {
                try await appViewModel.authManager.signUpWithEmail(email: email, password: password)
            } else {
                try await appViewModel.authManager.signInWithEmail(email: email, password: password)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
