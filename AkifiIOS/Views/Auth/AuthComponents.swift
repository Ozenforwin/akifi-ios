import SwiftUI
import UIKit
import Supabase

// MARK: - AuthTextField

struct AuthTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var errorMessage: String?
    var isValid: Bool?

    @State private var showPassword = false
    @FocusState private var isFocused: Bool

    /// What the field signals besides its text (1.6: no coloured borders —
    /// an error is the red icon + message, a valid value a green check).
    enum ValidationState: Equatable {
        case neutral, valid, invalid
    }

    static func validationState(errorMessage: String?, isValid: Bool?) -> ValidationState {
        if let errorMessage, !errorMessage.isEmpty { return .invalid }
        if isValid == true { return .valid }
        return .neutral
    }

    private var state: ValidationState {
        Self.validationState(errorMessage: errorMessage, isValid: isValid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(state == .invalid ? .red : .secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                if isSecure && !showPassword {
                    SecureField(placeholder, text: $text)
                        .textContentType(textContentType)
                        .focused($isFocused)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .textContentType(textContentType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                }

                if state == .valid {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }

                if isSecure {
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -12)
                    .accessibilityLabel(showPassword
                        ? String(localized: "auth.password.hide")
                        : String(localized: "auth.password.show"))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage, !errorMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(errorMessage)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

// MARK: - PasswordStrengthView

enum PasswordStrength: Int, CaseIterable {
    case weak = 1
    case fair = 2
    case good = 3
    case strong = 4

    var label: String {
        switch self {
        case .weak: String(localized: "auth.password.weak")
        case .fair: String(localized: "auth.password.fair")
        case .good: String(localized: "auth.password.good")
        case .strong: String(localized: "auth.password.strong")
        }
    }

    var color: Color {
        switch self {
        case .weak: .red
        case .fair: .orange
        case .good: .yellow
        case .strong: .green
        }
    }
}

struct PasswordStrengthView: View {
    let password: String

    var strength: PasswordStrength {
        var score = 0
        if password.count >= 8 { score += 1 }
        if password.range(of: "[A-Z]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[a-z]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[0-9]", options: .regularExpression) != nil { score += 1 }
        return PasswordStrength(rawValue: max(1, score)) ?? .weak
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Strength bar
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment <= strength.rawValue ? strength.color : Color(.separator))
                        .frame(height: 4)
                }
            }

            Text(strength.label)
                .font(.caption2)
                .foregroundStyle(strength.color)

            // Requirements checklist
            VStack(alignment: .leading, spacing: 4) {
                PasswordRequirement(
                    text: String(localized: "auth.password.req.length"),
                    met: password.count >= 8
                )
                PasswordRequirement(
                    text: String(localized: "auth.password.req.uppercase"),
                    met: password.range(of: "[A-Z]", options: .regularExpression) != nil
                )
                PasswordRequirement(
                    text: String(localized: "auth.password.req.lowercase"),
                    met: password.range(of: "[a-z]", options: .regularExpression) != nil
                )
                PasswordRequirement(
                    text: String(localized: "auth.password.req.digit"),
                    met: password.range(of: "[0-9]", options: .regularExpression) != nil
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: strength)
    }
}

private struct PasswordRequirement: View {
    let text: String
    let met: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? .green : .secondary)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? .primary : .secondary)
        }
    }
}

// MARK: - AuthButton

struct AuthButton: View {
    let title: String
    var isLoading: Bool = false
    var disabled: Bool = false
    var style: AuthButtonStyle = .primary
    let action: () -> Void

    enum AuthButtonStyle {
        case primary
        case secondary
    }

    /// System call-to-action (1.6): `.akifiPrimary` / `.akifiSecondary`,
    /// full width, large; the system draws the disabled state.
    var body: some View {
        let button = Button(action: {
            HapticManager.medium()
            action()
        }) {
            ZStack {
                // The title keeps its size while the spinner shows.
                Text(title)
                    .font(.headline)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(disabled || isLoading)

        switch style {
        case .primary: button.buttonStyle(.akifiPrimary)
        case .secondary: button.buttonStyle(.akifiSecondary)
        }
    }
}

// MARK: - Fits or scrolls

/// Full-screen layouts spaced with `Spacer`s (login, onboarding steps): at
/// regular text sizes the content fills the screen as designed; when large
/// Dynamic Type makes it taller than the screen it scrolls instead of being
/// cut off at both ends.
struct FitsOrScrolls: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension View {
    /// See `FitsOrScrolls`.
    func fitsOrScrolls() -> some View {
        modifier(FitsOrScrolls())
    }
}

// MARK: - ErrorToastView

struct ErrorToastView: View {
    let message: String
    let onDismiss: () -> Void

    /// A floating glass banner (1.6), like the app's other top banners:
    /// the red symbol carries the meaning, the text stays primary.
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close"))
        }
        // The 44 pt close button sets the height and the trailing spacing.
        .akifiGlassBanner(contentInsets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 4))
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - ErrorToast modifier

struct ErrorToastModifier: ViewModifier {
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = errorMessage {
                ErrorToastView(message: message) {
                    withAnimation { errorMessage = nil }
                }
                // Below the navigation bar's control row, never over its buttons.
                .padding(.top, AkifiChrome.bannerTopInset)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        withAnimation { errorMessage = nil }
                    }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: errorMessage)
    }
}

extension View {
    func errorToast(_ message: Binding<String?>) -> some View {
        modifier(ErrorToastModifier(errorMessage: message))
    }
}

// MARK: - AuthErrorMapper

enum AuthErrorMapper {
    /// Sign-in refused because the address was never confirmed — the UI
    /// offers to resend the confirmation email (A1).
    static func isEmailNotConfirmed(_ error: Error) -> Bool {
        if let authError = error as? AuthError, authError.errorCode == .emailNotConfirmed { return true }
        let desc = error.localizedDescription.lowercased()
        return desc.contains("email_not_confirmed") || desc.contains("email not confirmed")
    }

    static func message(for error: Error) -> String {
        // The server's error code first: the SDK's localizedDescription is
        // the human message ("Email not confirmed"), not the code, so the
        // substring checks below missed several cases.
        if let authError = error as? AuthError {
            switch authError.errorCode {
            case .invalidCredentials: return String(localized: "auth.error.invalidCredentials")
            case .userAlreadyExists, .emailExists: return String(localized: "auth.error.alreadyRegistered")
            case .emailNotConfirmed: return String(localized: "auth.error.emailNotConfirmed")
            case .overEmailSendRateLimit, .overRequestRateLimit: return String(localized: "auth.error.rateLimited")
            case .weakPassword: return String(localized: "auth.error.weakPassword")
            case .samePassword: return String(localized: "auth.error.samePassword")
            default: break
            }
        }
        let desc = error.localizedDescription.lowercased()

        if desc.contains("invalid_credentials") || desc.contains("invalid login") {
            return String(localized: "auth.error.invalidCredentials")
        }
        if desc.contains("user_already_registered") || desc.contains("already registered") {
            return String(localized: "auth.error.alreadyRegistered")
        }
        if desc.contains("email_not_confirmed") || desc.contains("email not confirmed") {
            return String(localized: "auth.error.emailNotConfirmed")
        }
        if desc.contains("over_email_send_rate_limit") || desc.contains("rate") {
            return String(localized: "auth.error.rateLimited")
        }
        if desc.contains("network") || desc.contains("internet") || desc.contains("offline") ||
           desc.contains("urlsessiontask") || desc.contains("nsurlerrordomain") {
            return String(localized: "auth.error.network")
        }
        if desc.contains("weak_password") || desc.contains("should be at least") {
            return String(localized: "auth.error.weakPassword")
        }

        return String(localized: "auth.error.generic")
    }
}

// MARK: - Email Validation

enum EmailValidator {
    static func isValid(_ email: String) -> Bool {
        let pattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }
}
