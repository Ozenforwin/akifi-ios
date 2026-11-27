import SwiftUI

/// One-time consent before the first assistant request (R8): names the
/// third-party AI providers and what is sent to them. Nothing is sent
/// until the user taps "Разрешить"; closing the sheet is a decline.
struct AIConsentSheet: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 44

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Spacer()
                        // The Assistant's own avatar keeps the AI gradient.
                        Image(systemName: "sparkles")
                            .font(.system(size: avatarSize))
                            .foregroundStyle(
                                LinearGradient(colors: [.aiGradientStart, .aiGradientEnd],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .accessibilityHidden(true)
                        Spacer()
                    }

                    Text(String(localized: "assistant.consent.title"))
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "assistant.consent.intro \(AIConsentStore.providers.formatted(.list(type: .and)))"))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "assistant.consent.sentHeader"))
                            .font(.headline)
                        bullet("text.bubble", String(localized: "assistant.consent.item.question"))
                        bullet("list.bullet.rectangle", String(localized: "assistant.consent.item.transactions"))
                        bullet("creditcard", String(localized: "assistant.consent.item.accounts"))
                        bullet("clock.arrow.circlepath", String(localized: "assistant.consent.item.history"))
                    }
                    .akifiCard()

                    Text(String(localized: "assistant.consent.notSent"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(String(localized: "assistant.consent.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let privacyURL = URL(string: "https://akifi.pro/privacy") {
                        Link(String(localized: "auth.privacyPolicy"), destination: privacyURL)
                            .font(.footnote.weight(.medium))
                            .frame(minHeight: 44)
                    }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .akifiBottomBar {
                VStack(spacing: 8) {
                    Button(action: onAccept) {
                        Text(String(localized: "assistant.consent.accept"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.akifiPrimary)
                    .controlSize(.large)

                    Button(action: onDecline) {
                        Text(String(localized: "assistant.consent.decline"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.akifiSecondary)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close"), action: onDecline)
                }
            }
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
