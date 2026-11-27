import SwiftUI

// Toolbar items of the tab roots (1.6). They replace the hand-made
// `AppHeaderView` row: the system navigation bar (glass on iOS 26) now
// carries the title, and these are its top-trailing items.

// MARK: - Profile / settings avatar

/// Top-trailing avatar button that opens Settings. Shows the profile photo
/// when there is one, a person symbol otherwise; VoiceOver reads the
/// user's name. Carries the `.profileAvatar` spotlight anchor.
struct ProfileAvatarButton: View {
    @Environment(AppViewModel.self) private var appViewModel
    let action: () -> Void

    /// Avatar diameter — fits the 44 pt navigation-bar hit target.
    private let size: CGFloat = 32

    var body: some View {
        Button(action: action) {
            avatar
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .spotlight(.profileAvatar)
        .accessibilityLabel(String(localized: "spotlight.profile.title"))
        .accessibilityValue(Self.displayName(
            fullName: appViewModel.dataStore.profile?.fullName,
            email: appViewModel.authManager.currentUser?.email
        ))
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarUrl = appViewModel.dataStore.profile?.avatarUrl,
           let url = URL(string: avatarUrl) {
            CachedAsyncImage(url: url) { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
    }

    /// Name shown for the signed-in user: the profile name, else the part
    /// of the email before "@" (what the old header row displayed).
    static func displayName(fullName: String?, email: String?) -> String {
        if let fullName, !fullName.isEmpty { return fullName }
        let local = (email ?? "").components(separatedBy: "@").first ?? ""
        return local.isEmpty ? "User" : local
    }
}

// MARK: - Display-currency switcher

/// Display-currency switcher: inline `Menu` over the user's active
/// currencies (managed in Settings → "My currencies") so the most-used
/// one-tap switch stays fast. "All currencies…" is the escape hatch for
/// one-off switches without polluting the active list.
struct DisplayCurrencyMenu: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showFullPicker = false
    @State private var fullPickerSelection: Currency = .rub
    private let prefs = UserCurrencyPreferences.shared

    var body: some View {
        let selected = appViewModel.currencyManager.selectedCurrency
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
                    if currency == selected {
                        Label(
                            "\(currency.symbol)  \(currency.code)",
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(verbatim: "\(currency.symbol)  \(currency.code)")
                    }
                }
            }
            Divider()
            Button {
                fullPickerSelection = selected
                showFullPicker = true
            } label: {
                Label(
                    String(localized: "currencyPicker.allCurrencies"),
                    systemImage: "ellipsis.circle"
                )
            }
        } label: {
            Text(verbatim: selected.symbol)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 28, minHeight: 28)
        }
        .accessibilityLabel(String(localized: "common.currency"))
        .accessibilityValue(Text(verbatim: selected.code))
        .sheet(isPresented: $showFullPicker, onDismiss: {
            if fullPickerSelection != appViewModel.currencyManager.selectedCurrency {
                appViewModel.currencyManager.selectedCurrency = fullPickerSelection
            }
        }) {
            CurrencyPickerView(selection: $fullPickerSelection)
        }
    }
}

// MARK: - Toolbar content

/// Home's top-trailing items: currency switcher, then the avatar. On iOS 26
/// the avatar sits outside the shared glass capsule (a photo doesn't need
/// a glass plate) with a fixed gap between the two groups.
struct HomeTabToolbar: ToolbarContent {
    let onProfile: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            DisplayCurrencyMenu()
        }
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                ProfileAvatarButton(action: onProfile)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                ProfileAvatarButton(action: onProfile)
            }
        }
    }
}
