import SwiftUI
import UIKit

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

    private var borderColor: Color {
        if let errorMessage, !errorMessage.isEmpty { return .red }
        if let isValid, isValid { return .green }
        return isFocused ? Color.accent : Color(.separator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(borderColor == .red ? .red : .secondary)
                    .frame(width: 20)

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

                if isSecure {
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: isFocused || errorMessage != nil ? 1.5 : 0.5)
            )

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
        .animation(.easeInOut(duration: 0.2), value: isFocused)
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

    var body: some View {
        Button(action: {
            HapticManager.medium()
            action()
        }) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(style == .primary ? .white : .accent)
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .background(style == .primary ? Color.accent : Color(uiColor: .secondarySystemGroupedBackground))
        .foregroundStyle(style == .primary ? Color.white : Color.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .opacity(disabled || isLoading ? 0.6 : 1)
        .disabled(disabled || isLoading)
    }
}

// MARK: - ErrorToastView

struct ErrorToastView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.red.gradient, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
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
    static func message(for error: Error) -> String {
        let desc = error.localizedDescription.lowercased()

        if desc.contains("invalid_credentials") || desc.contains("invalid login") {
            return String(localized: "auth.error.invalidCredentials")
        }
        if desc.contains("user_already_registered") || desc.contains("already registered") {
            return String(localized: "auth.error.alreadyRegistered")
        }
        if desc.contains("email_not_confirmed") {
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
