import SwiftUI
import UIKit

struct ForgotPasswordView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var emailError: String?
    @State private var hasInteracted = false
    @State private var isLoading = false
    @State private var isSent = false
    @State private var errorMessage: String?
    @State private var resendCountdown = 0

    private var isEmailValid: Bool {
        EmailValidator.isValid(email)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isSent {
                    sentView
                } else {
                    inputView
                }
            }
            .padding(24)
            .navigationTitle(String(localized: "auth.resetPassword"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
        .errorToast($errorMessage)
    }

    // MARK: - Input View

    private var inputView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 50))
                    .foregroundStyle(Color.accent.gradient)

                Text(String(localized: "auth.resetPassword.title"))
                    .font(.title2.bold())

                Text(String(localized: "auth.resetPassword.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            AuthTextField(
                icon: "envelope",
                placeholder: "Email",
                text: $email,
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                errorMessage: hasInteracted ? emailError : nil,
                isValid: hasInteracted && emailError == nil && !email.isEmpty ? true : nil
            )
            .onChange(of: email) {
                hasInteracted = true
                if email.isEmpty {
                    emailError = String(localized: "auth.error.emailRequired")
                } else if !isEmailValid {
                    emailError = String(localized: "auth.error.emailInvalid")
                } else {
                    emailError = nil
                }
            }

            AuthButton(
                title: String(localized: "auth.sendResetLink"),
                isLoading: isLoading,
                disabled: !isEmailValid
            ) {
                Task { await sendResetLink() }
            }

            Spacer()
        }
    }

    // MARK: - Sent View

    private var sentView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.accent.gradient)

                Text(String(localized: "auth.checkInbox"))
                    .font(.title2.bold())

                Text(String(localized: "auth.resetPassword.sentTo.\(email)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                // Open email app
                if let mailURL = URL(string: "message://"), UIApplication.shared.canOpenURL(mailURL) {
                    Button {
                        UIApplication.shared.open(mailURL)
                    } label: {
                        HStack {
                            Image(systemName: "envelope.open")
                            Text(String(localized: "auth.openEmailApp"))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .background(Color.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                // Resend button
                Button {
                    Task { await sendResetLink() }
                } label: {
                    if resendCountdown > 0 {
                        Text(String(localized: "auth.resendIn.\(resendCountdown)"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "auth.resend"))
                            .font(.subheadline)
                            .foregroundStyle(Color.accent)
                    }
                }
                .disabled(resendCountdown > 0 || isLoading)

                // Back to sign in
                Button(String(localized: "auth.backToSignIn")) {
                    dismiss()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func sendResetLink() async {
        hasInteracted = true
        guard isEmailValid else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await appViewModel.authManager.resetPassword(email: email)
            withAnimation { isSent = true }
            startCountdown()
        } catch {
            errorMessage = AuthErrorMapper.message(for: error)
        }

        isLoading = false
    }

    private func startCountdown() {
        resendCountdown = 60
        Task {
            while resendCountdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                resendCountdown -= 1
            }
        }
    }
}
