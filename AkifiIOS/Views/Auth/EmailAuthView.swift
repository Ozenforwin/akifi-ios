import SwiftUI

struct EmailAuthView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showForgotPassword = false
    /// Sign-up went through but needs the emailed link (A1): the sheet
    /// shows "check your inbox" instead of closing silently.
    @State private var confirmationEmail: String?
    /// Sign-in refused with email_not_confirmed for this address — offer
    /// to resend the confirmation.
    @State private var unconfirmedEmail: String?
    @State private var isResendingConfirmation = false

    // Validation states
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var confirmError: String?
    @State private var hasInteractedEmail = false
    @State private var hasInteractedPassword = false
    @State private var hasInteractedConfirm = false

    enum AuthMode: String, CaseIterable {
        case signIn, signUp

        var title: String {
            switch self {
            case .signIn: String(localized: "auth.signIn")
            case .signUp: String(localized: "auth.signUp")
            }
        }
    }

    private var isFormValid: Bool {
        let emailValid = EmailValidator.isValid(email)
        if mode == .signIn {
            return emailValid && !password.isEmpty
        }
        return emailValid && password.count >= 8 &&
            password.range(of: "[A-Z]", options: .regularExpression) != nil &&
            password.range(of: "[a-z]", options: .regularExpression) != nil &&
            password.range(of: "[0-9]", options: .regularExpression) != nil &&
            confirmPassword == password
    }

    var body: some View {
        @Bindable var auth = appViewModel.authManager
        NavigationStack {
            ScrollView {
                if let confirmationEmail {
                    EmailConfirmationPendingView(
                        email: confirmationEmail,
                        onResend: {
                            try await appViewModel.authManager.resendSignupConfirmation(email: confirmationEmail)
                        },
                        onChangeEmail: {
                            withAnimation { self.confirmationEmail = nil }
                        },
                        onSignIn: {
                            withAnimation {
                                self.confirmationEmail = nil
                                mode = .signIn
                                password = ""
                                confirmPassword = ""
                            }
                        }
                    )
                    .padding(24)
                } else {
                    form
                }
            }
            // Fields are content cards on the grouped background (1.6).
            .background(Color(.systemGroupedBackground))
            .navigationTitle(confirmationEmail == nil ? mode.title : String(localized: "auth.signUp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .onChange(of: mode) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    // Reset errors on mode switch
                    emailError = nil
                    passwordError = nil
                    confirmError = nil
                    hasInteractedEmail = false
                    hasInteractedPassword = false
                    hasInteractedConfirm = false
                    errorMessage = nil
                    unconfirmedEmail = nil
                }
            }
            .sheet(isPresented: $showForgotPassword) {
                ForgotPasswordView()
            }
            .animation(.easeInOut(duration: 0.25), value: mode)
        }
        .errorToast($errorMessage)
        // A confirmation link that failed while this sheet is up (A1).
        .errorToast($auth.authLinkError)
    }

    private var form: some View {
                VStack(spacing: 24) {
                    // Mode picker
                    Picker(String(localized: "auth.signIn"), selection: $mode) {
                        ForEach(AuthMode.allCases, id: \.self) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Email field
                    AuthTextField(
                        icon: "envelope",
                        placeholder: "Email",
                        text: $email,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress,
                        errorMessage: hasInteractedEmail ? emailError : nil,
                        isValid: hasInteractedEmail && emailError == nil && !email.isEmpty ? true : nil
                    )
                    .onChange(of: email) { validateEmail() }

                    // Password field
                    AuthTextField(
                        icon: "lock",
                        placeholder: String(localized: "auth.password"),
                        text: $password,
                        isSecure: true,
                        textContentType: mode == .signUp ? .newPassword : .password,
                        errorMessage: hasInteractedPassword ? passwordError : nil
                    )
                    .onChange(of: password) {
                        validatePassword()
                        if mode == .signUp && hasInteractedConfirm {
                            validateConfirmPassword()
                        }
                    }

                    // Password strength (sign up only)
                    if mode == .signUp && !password.isEmpty {
                        PasswordStrengthView(password: password)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Confirm password (sign up only)
                    if mode == .signUp {
                        AuthTextField(
                            icon: "lock.badge.checkmark",
                            placeholder: String(localized: "auth.confirmPassword"),
                            text: $confirmPassword,
                            isSecure: true,
                            textContentType: .newPassword,
                            errorMessage: hasInteractedConfirm ? confirmError : nil,
                            isValid: hasInteractedConfirm && confirmError == nil && !confirmPassword.isEmpty ? true : nil
                        )
                        .onChange(of: confirmPassword) { validateConfirmPassword() }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Forgot password (sign in only)
                    if mode == .signIn {
                        HStack {
                            Spacer()
                            Button(String(localized: "auth.forgotPassword")) {
                                showForgotPassword = true
                            }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                        }
                    }

                    // Submit button
                    AuthButton(
                        title: mode == .signIn ? String(localized: "auth.signIn") : String(localized: "auth.createAccount"),
                        isLoading: isLoading,
                        disabled: !isFormValid
                    ) {
                        Task { await authenticate() }
                    }

                    // Sign-in refused: the address was never confirmed (A1).
                    if mode == .signIn, let unconfirmedEmail, unconfirmedEmail == email {
                        VStack(spacing: 6) {
                            Text(String(localized: "auth.signIn.notConfirmed"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button {
                                Task { await resendConfirmation(to: unconfirmedEmail) }
                            } label: {
                                if isResendingConfirmation {
                                    ProgressView()
                                } else {
                                    Text(String(localized: "auth.signIn.resendConfirmation"))
                                }
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .disabled(isResendingConfirmation)
                        }
                        .transition(.opacity)
                    }

                    // Terms (sign up only)
                    if mode == .signUp {
                        Text(String(localized: "auth.agreeTerms"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
    }

    private func resendConfirmation(to address: String) async {
        isResendingConfirmation = true
        do {
            try await appViewModel.authManager.resendSignupConfirmation(email: address)
            withAnimation {
                unconfirmedEmail = nil
                confirmationEmail = address
            }
        } catch {
            errorMessage = AuthErrorMapper.message(for: error)
        }
        isResendingConfirmation = false
    }

    // MARK: - Validation

    private func validateEmail() {
        hasInteractedEmail = true
        if email.isEmpty {
            emailError = String(localized: "auth.error.emailRequired")
        } else if !EmailValidator.isValid(email) {
            emailError = String(localized: "auth.error.emailInvalid")
        } else {
            emailError = nil
        }
    }

    private func validatePassword() {
        hasInteractedPassword = true
        if mode == .signUp {
            if password.isEmpty {
                passwordError = String(localized: "auth.error.passwordRequired")
            } else if password.count < 8 {
                passwordError = String(localized: "auth.error.passwordTooShort")
            } else {
                passwordError = nil
            }
        } else {
            passwordError = password.isEmpty ? String(localized: "auth.error.passwordRequired") : nil
        }
    }

    private func validateConfirmPassword() {
        hasInteractedConfirm = true
        if confirmPassword.isEmpty {
            confirmError = String(localized: "auth.error.confirmRequired")
        } else if confirmPassword != password {
            confirmError = String(localized: "auth.error.passwordsMismatch")
        } else {
            confirmError = nil
        }
    }

    // MARK: - Auth

    private func authenticate() async {
        // Validate all fields before submitting
        validateEmail()
        validatePassword()
        if mode == .signUp { validateConfirmPassword() }

        guard isFormValid else { return }

        isLoading = true
        errorMessage = nil

        do {
            if mode == .signUp {
                let outcome = try await appViewModel.authManager.signUpWithEmail(email: email, password: password)
                switch outcome {
                case .signedIn:
                    dismiss()
                case .confirmationRequired(let address):
                    withAnimation { confirmationEmail = address }
                }
            } else {
                try await appViewModel.authManager.signInWithEmail(email: email, password: password)
                dismiss()
            }
        } catch {
            if mode == .signIn, AuthErrorMapper.isEmailNotConfirmed(error) {
                withAnimation { unconfirmedEmail = email }
            }
            errorMessage = AuthErrorMapper.message(for: error)
        }

        isLoading = false
    }
}
