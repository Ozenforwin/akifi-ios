import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "settings.profile")) {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text(appViewModel.authManager.currentUser?.email ?? "Пользователь")
                                    .font(.headline)
                                Text(String(localized: "settings.editProfile"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(String(localized: "settings.finances")) {
                    NavigationLink {
                        SavingsGoalListView()
                    } label: {
                        Label(String(localized: "home.savings"), systemImage: "target")
                    }

                    NavigationLink {
                        SubscriptionListView()
                    } label: {
                        Label(String(localized: "subscriptions.title"), systemImage: "repeat.circle")
                    }

                    NavigationLink {
                        AchievementsView()
                    } label: {
                        Label(String(localized: "achievements.title"), systemImage: "trophy")
                    }
                }

                Section(String(localized: "settings.app")) {
                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        Label(String(localized: "settings.currency"), systemImage: "dollarsign.circle")
                    }

                    NavigationLink {
                        CategoriesManagementView()
                    } label: {
                        Label(String(localized: "budgets.categories"), systemImage: "tag")
                    }

                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label(String(localized: "settings.notifications"), systemImage: "bell")
                    }
                }

                Section("Premium") {
                    NavigationLink {
                        PremiumPaywallView()
                    } label: {
                        HStack {
                            Label(String(localized: "premium.title"), systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                            Spacer()
                            if appViewModel.paymentManager.isPremium {
                                Text(String(localized: "premium.active"))
                                    .font(.caption)
                                    .foregroundStyle(.green)
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
                                .foregroundStyle(.green)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Валюта")
    }
}
