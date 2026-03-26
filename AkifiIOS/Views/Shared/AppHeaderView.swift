import SwiftUI

struct AppHeaderView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Binding var showProfile: Bool
    var showCurrencyPicker: Binding<Bool>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showProfile = true
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(
                                    appViewModel.paymentManager.isPremium
                                        ? Color.tierGold
                                        : Color.gray.opacity(0.3),
                                    lineWidth: 2
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }

                        Text(displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if appViewModel.paymentManager.isPremium {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.tierGold)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if let currencyBinding = showCurrencyPicker {
                    Button {
                        currencyBinding.wrappedValue = true
                    } label: {
                        Text(appViewModel.currencyManager.selectedCurrency.symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    toggleColorScheme()
                } label: {
                    Image(systemName: currentSchemeIcon)
                        .font(.system(size: 14))
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
        }
    }

    private var displayName: String {
        let email = appViewModel.authManager.currentUser?.email
        if let email {
            return email.components(separatedBy: "@").first ?? email
        }
        return "User"
    }

    private var currentSchemeIcon: String {
        let isDark = UserDefaults.standard.bool(forKey: "dark_mode")
        return isDark ? "moon.fill" : "sun.max.fill"
    }

    private func toggleColorScheme() {
        let isDark = UserDefaults.standard.bool(forKey: "dark_mode")
        UserDefaults.standard.set(!isDark, forKey: "dark_mode")
    }
}
