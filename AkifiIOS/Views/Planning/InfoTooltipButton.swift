import SwiftUI

/// Inline info-circle button that opens an explanatory sheet for a
/// single metric. Used throughout the BETA "Инвестиции" surfaces to
/// teach the concepts behind the numbers (4% rule, savings rate,
/// investable assets, expected return) without making the screen
/// itself heavy with copy.
///
/// Visual: a `.secondary`-tinted SF symbol that doesn't fight the
/// label it sits next to; its hit area is padded to 44 pt without
/// changing the row's layout. The sheet uses the `.medium` detent —
/// enough room for one paragraph and a "Got it" button.
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
                .font(.footnote)
                .foregroundStyle(.secondary)
                // 44 pt hit target, layout unchanged.
                .padding(14)
                .contentShape(Rectangle())
                .padding(-14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: titleKey)))
        .sheet(isPresented: $isPresented) {
            InfoSheet(titleKey: titleKey, bodyKey: bodyKey, isPresented: $isPresented)
                .presentationDetents([.medium])
        }
    }
}

private struct InfoSheet: View {
    let titleKey: String.LocalizationValue
    let bodyKey: String.LocalizationValue
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(String(localized: bodyKey))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    isPresented = false
                } label: {
                    Text(String(localized: "common.gotIt"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.akifiPrimary)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationTitle(String(localized: titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { isPresented = false }
                }
            }
        }
    }
}
