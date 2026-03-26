import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Профиль") {
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
                                Text("Редактировать профиль")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Финансы") {
                    NavigationLink {
                        SavingsGoalListView()
                    } label: {
                        Label("Накопления", systemImage: "target")
                    }

                    NavigationLink {
                        SubscriptionListView()
                    } label: {
                        Label("Подписки", systemImage: "repeat.circle")
                    }

                    NavigationLink {
                        AchievementsView()
                    } label: {
                        Label("Достижения", systemImage: "trophy")
                    }
                }

                Section("Приложение") {
                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        Label("Валюта", systemImage: "dollarsign.circle")
                    }

                    NavigationLink {
                        CategoriesManagementView()
                    } label: {
                        Label("Категории", systemImage: "tag")
                    }

                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Уведомления", systemImage: "bell")
                    }
                }

                Section("Premium") {
                    NavigationLink {
                        PremiumPaywallView()
                    } label: {
                        HStack {
                            Label("Akifi Pro", systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                            Spacer()
                            if appViewModel.paymentManager.isPremium {
                                Text("Активно")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section("О приложении") {
                    HStack {
                        Text("Версия")
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
                        Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Настройки")
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
