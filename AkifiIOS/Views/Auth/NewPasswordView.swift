import SwiftUI

/// Shown after a password-reset link signed the user in (A1). Before this
/// screen existed the reset could never be finished: the link led to the
/// old web site and the app had nowhere to type the new password.
struct NewPasswordView: View {
    @Environment(AppViewModel.self) private var appViewModel

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var hasInteractedConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isDone = false
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 50

    /// Same rules as sign-up (EmailAuthView).
    nonisolated static func isAcceptable(_ password: String, confirmation: String) -> Bool {
        password.count >= 8
            && password.range(of: "[A-Z]", options: .regularExpression) != nil
            && password.range(of: "[a-z]", options: .regularExpression) != nil
            && password.range(of: "[0-9]", options: .regularExpression) != nil
            && password == confirmation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if isDone {
                        doneView
                    } else {
                        formView
                    }
                }
                .padding(24)
            }
            // Fields are content cards on the grouped background (1.6).
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "auth.newPassword.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isDone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "auth.newPassword.later")) {
                            appViewModel.authManager.dismissPasswordRecovery()
                        }
                    }
                }
            }
        }
        .tint(Color.accent)
        .errorToast($errorMessage)
    }

    private var formView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: iconSize))
                    .foregroundStyle(Color.accent)
                    .accessibilityHidden(true)
                Text(String(localized: "auth.newPassword.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AuthTextField(
                icon: "lock",
                placeholder: String(localized: "auth.newPassword.field"),
                text: $password,
                isSecure: true,
                textContentType: .newPassword
            )

            if !password.isEmpty {
                PasswordStrengthView(password: password)
            }

            AuthTextField(
                icon: "lock.badge.checkmark",
                placeholder: String(localized: "auth.confirmPassword"),
                text: $confirmPassword,
                isSecure: true,
                textContentType: .newPassword,
                errorMessage: hasInteractedConfirm && !confirmPassword.isEmpty && confirmPassword != password
                    ? String(localized: "auth.error.passwordsMismatch") : nil
            )
            .onChange(of: confirmPassword) { hasInteractedConfirm = true }

            AuthButton(
                title: String(localized: "auth.newPassword.save"),
                isLoading: isSaving,
                disabled: !Self.isAcceptable(password, confirmation: confirmPassword)
            ) {
                Task { await save() }
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(String(localized: "auth.newPassword.done"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            AuthButton(title: String(localized: "auth.newPassword.continue")) {
                appViewModel.authManager.dismissPasswordRecovery()
            }
        }
        .padding(.top, 40)
    }

    private func save() async {
        guard Self.isAcceptable(password, confirmation: confirmPassword) else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await appViewModel.authManager.updatePassword(password)
            withAnimation { isDone = true }
        } catch {
            errorMessage = AuthErrorMapper.message(for: error)
        }
        isSaving = false
    }
}
