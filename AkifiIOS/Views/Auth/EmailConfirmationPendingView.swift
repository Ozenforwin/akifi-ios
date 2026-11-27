import SwiftUI
import UIKit

/// "Check your inbox" after an email sign-up that needs confirmation (A1).
/// Sign-up used to close the sheet silently, and the user never learned an
/// email was waiting. The link opens the app (akifi://auth-callback) and
/// signs the user in; until then they can resend, fix the address, or go
/// to sign-in if they already confirmed.
struct EmailConfirmationPendingView: View {
    let email: String
    let onResend: () async throws -> Void
    let onChangeEmail: () -> Void
    let onSignIn: () -> Void

    /// The email was just sent — the first resend waits a minute (the
    /// project's mail quota is small).
    @State private var resendCountdown = 60
    @State private var countdownEpoch = 0
    @State private var isResending = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: iconSize))
                    .foregroundStyle(Color.accent)
                    .accessibilityHidden(true)

                Text(String(localized: "auth.checkInbox"))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                Text(String(localized: "auth.signUp.confirmSent \(email)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "auth.signUp.spamHint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)

            VStack(spacing: 12) {
                if let mailURL = URL(string: "message://"), UIApplication.shared.canOpenURL(mailURL) {
                    Button {
                        UIApplication.shared.open(mailURL)
                    } label: {
                        Label(String(localized: "auth.openEmailApp"), systemImage: "envelope.open")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.akifiPrimary)
                    .controlSize(.large)
                }

                Button {
                    Task { await resend() }
                } label: {
                    Group {
                        if isResending {
                            ProgressView()
                        } else if resendCountdown > 0 {
                            Text(String(localized: "auth.resendIn.\(resendCountdown)"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "auth.resend"))
                                .foregroundStyle(Color.accent)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(resendCountdown > 0 || isResending)

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                Button(String(localized: "auth.signUp.alreadyConfirmed"), action: onSignIn)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)

                Button(String(localized: "auth.signUp.changeEmail"), action: onChangeEmail)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
        }
        .errorToast($errorMessage)
        .task(id: countdownEpoch) {
            while resendCountdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                resendCountdown -= 1
            }
        }
    }

    private func resend() async {
        isResending = true
        errorMessage = nil
        notice = nil
        do {
            try await onResend()
            notice = String(localized: "auth.signUp.resent")
            resendCountdown = 60
            countdownEpoch += 1
        } catch {
            errorMessage = AuthErrorMapper.message(for: error)
        }
        isResending = false
    }
}
