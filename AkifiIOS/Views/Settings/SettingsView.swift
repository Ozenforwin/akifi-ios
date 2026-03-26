import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Profile header
                Section {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(
                                    appViewModel.paymentManager.isPremium
                                        ? Color.tierGold
                                        : Color.gray.opacity(0.3),
                                    lineWidth: 3
                                )
                                .frame(width: 80, height: 80)

                            Image(systemName: "person.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                        }

                        Text(appViewModel.authManager.currentUser?.email ?? "User")
                            .font(.headline)

                        if appViewModel.paymentManager.isPremium {
                            Text("Premium")
                                .font(.caption)
                                .foregroundStyle(Color.tierGold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section(header: Text("ОСНОВНОЕ")) {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        SettingsRow(icon: "person.fill", color: .accent, title: String(localized: "settings.profile"))
                    }

                    NavigationLink {
                        CategoriesManagementView()
                    } label: {
                        SettingsRow(icon: "tag.fill", color: .orange, title: String(localized: "budgets.categories"))
                    }
                }

                Section(header: Text("НАСТРОЙКИ")) {
                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        SettingsRow(icon: "dollarsign.circle.fill", color: .green, title: String(localized: "settings.currency"), value: appViewModel.currencyManager.selectedCurrency.symbol)
                    }

                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        SettingsRow(icon: "bell.fill", color: .orange, title: String(localized: "settings.notifications"))
                    }
                }

                Section(header: Text("ФИНАНСЫ")) {
                    NavigationLink {
                        SavingsGoalListView()
                    } label: {
                        SettingsRow(icon: "target", color: .green, title: String(localized: "home.savings"))
                    }

                    NavigationLink {
                        SubscriptionListView()
                    } label: {
                        SettingsRow(icon: "repeat.circle.fill", color: .accent, title: String(localized: "subscriptions.title"))
                    }

                    NavigationLink {
                        AchievementsView()
                    } label: {
                        SettingsRow(icon: "trophy.fill", color: .yellow, title: String(localized: "achievements.title"))
                    }
                }

                Section(header: Text("Premium")) {
                    NavigationLink {
                        PremiumPaywallView()
                    } label: {
                        HStack {
                            SettingsRow(icon: "star.fill", color: .yellow, title: String(localized: "premium.title"))
                            if appViewModel.paymentManager.isPremium {
                                Text(String(localized: "premium.active"))
                                    .font(.caption)
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                }

                Section(String(localized: "settings.about")) {
                    HStack {
                        Text(String(localized: "common.version"))
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            try? await appViewModel.authManager.signOut()
                        }
                    } label: {
                        Label(String(localized: "auth.signOut"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle(String(localized: "common.settings"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(title)

            if let value {
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CurrencyPickerView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        List {
            ForEach(CurrencyCode.allCases, id: \.self) { currency in
                Button {
                    appViewModel.currencyManager.selectedCurrency = currency
                } label: {
                    HStack {
                        Text(currency.symbol)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(currency.rawValue)
                                .font(.headline)
                            Text(currency.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appViewModel.currencyManager.selectedCurrency == currency {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Валюта")
    }
}
