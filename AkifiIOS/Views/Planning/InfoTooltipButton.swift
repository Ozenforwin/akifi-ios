import SwiftUI

/// Inline info-circle button that opens an explanatory sheet for a
/// single metric. Used throughout the BETA "Инвестиции" surfaces to
/// teach the concepts behind the numbers (4% rule, savings rate,
/// investable assets, expected return) without making the screen
/// itself heavy with copy.
///
/// Visual: a `.tertiary`-tinted SF symbol that doesn't fight the
/// label it sits next to. The sheet itself uses `.medium` detent —
/// enough room for one paragraph and a "Got it" dismiss button.
///
/// All copy comes from `Localizable.xcstrings` so ru/en/es follow
/// the rest of the app.
struct InfoTooltipButton: View {
    let titleKey: String.LocalizationValue
    let bodyKey: String.LocalizationValue

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: titleKey)))
        .sheet(isPresented: $isPresented) {
            InfoSheet(titleKey: titleKey, bodyKey: bodyKey, isPresented: $isPresented)
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
    }
}

private struct InfoSheet: View {
    let titleKey: String.LocalizationValue
    let bodyKey: String.LocalizationValue
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(String(localized: titleKey))
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(String(localized: bodyKey))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                isPresented = false
            } label: {
                Text(String(localized: "common.gotIt"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }
}
