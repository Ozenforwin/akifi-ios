import SwiftUI

struct AppHeaderView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Binding var showProfile: Bool
    @State private var showFullPicker = false
    @State private var fullPickerSelection: Currency = .rub
    private let prefs = UserCurrencyPreferences.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showProfile = true
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                            .frame(width: 36, height: 36)

                        if let avatarUrl = appViewModel.dataStore.profile?.avatarUrl,
                           let url = URL(string: avatarUrl) {
                            CachedAsyncImage(url: url) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                }
            }
            .buttonStyle(.plain)
            .spotlight(.profileAvatar)

            Spacer()

            // Display-currency switcher. Inline `Menu` over the user's
            // active currencies (managed in Settings → "My currencies") so
            // the most-used one-tap switch stays fast. The "All currencies…"
            // row is the escape hatch for one-off switches without polluting
            // the active list.
            Menu {
                ForEach(prefs.activeCurrencies) { currency in
                    Button {
                        appViewModel.currencyManager.selectedCurrency = currency
                    } label: {
                        // Short label inside inline Menu so the row never wraps
                        // — Apple wraps long localized names ("Российский рубль")
                        // onto two lines and the menu becomes ugly. Symbol + ISO
                        // code is enough to identify the currency at a glance;
                        // full names live in the full-list sheet escape hatch.
                        if currency == appViewModel.currencyManager.selectedCurrency {
                            Label(
                                "\(currency.symbol)  \(currency.code)",
                                systemImage: "checkmark"
                            )
                        } else {
                            Text("\(currency.symbol)  \(currency.code)")
                        }
                    }
                }
                Divider()
                Button {
                    fullPickerSelection = appViewModel.currencyManager.selectedCurrency
                    showFullPicker = true
                } label: {
                    Label(
                        String(localized: "currencyPicker.allCurrencies"),
                        systemImage: "ellipsis.circle"
                    )
                }
            } label: {
                Text(appViewModel.currencyManager.selectedCurrency.symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel(String(localized: "common.currency"))
            .sheet(isPresented: $showFullPicker, onDismiss: {
                if fullPickerSelection != appViewModel.currencyManager.selectedCurrency {
                    appViewModel.currencyManager.selectedCurrency = fullPickerSelection
                }
            }) {
                CurrencyPickerView(selection: $fullPickerSelection)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var displayName: String {
        if let name = appViewModel.dataStore.profile?.fullName, !name.isEmpty {
            return name
        }
        let email = appViewModel.authManager.currentUser?.email ?? ""
        return email.components(separatedBy: "@").first ?? "User"
    }
}
