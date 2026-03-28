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

                            if let avatarUrl = appViewModel.dataStore.profile?.avatarUrl,
                               let url = URL(string: avatarUrl) {
                                CachedAsyncImage(url: url) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 74, height: 74)
                                .clipShape(Circle())
                            } else {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(appViewModel.dataStore.profile?.fullName ?? appViewModel.authManager.currentUser?.email ?? "User")
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

                // Stats
                Section {
                    HStack(spacing: 16) {
                        StatBadge(value: "\(appViewModel.dataStore.accounts.count)", label: "Счетов")
                        StatBadge(value: "\(appViewModel.dataStore.transactions.count)", label: "Операций")
                        StatBadge(value: "\(appViewModel.dataStore.categories.count)", label: "Категорий")
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
                        AISettingsView()
                    } label: {
                        SettingsRow(icon: "sparkles", color: .purple, title: "AI ассистент")
                    }

                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        SettingsRow(icon: "bell.fill", color: .orange, title: String(localized: "settings.notifications"))
                    }

                    // Theme
                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        SettingsRow(icon: "paintbrush.fill", color: .indigo, title: "Тема", value: appViewModel.themeManager.themeName)
                    }

                    // Category Layout
                    NavigationLink {
                        CategoryLayoutPickerView()
                    } label: {
                        SettingsRow(icon: "square.grid.2x2", color: .teal, title: "Вид категорий")
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

                Section(header: Text("ДАННЫЕ")) {
                    NavigationLink {
                        ExportView()
                    } label: {
                        SettingsRow(icon: "square.and.arrow.up", color: .blue, title: "Экспорт CSV")
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

                Color.clear.frame(height: 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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

struct StatBadge: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ThemePickerView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        List {
            Button {
                appViewModel.themeManager.setTheme(nil)
            } label: {
                HStack {
                    Label("Системная", systemImage: "gear")
                        .foregroundStyle(.primary)
                    Spacer()
                    if appViewModel.themeManager.selectedScheme == nil {
                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                    }
                }
            }

            Button {
                appViewModel.themeManager.setTheme(.light)
            } label: {
                HStack {
                    Label("Светлая", systemImage: "sun.max.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    if appViewModel.themeManager.selectedScheme == .light {
                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                    }
                }
            }

            Button {
                appViewModel.themeManager.setTheme(.dark)
            } label: {
                HStack {
                    Label("Тёмная", systemImage: "moon.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    if appViewModel.themeManager.selectedScheme == .dark {
                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                    }
                }
            }
        }
        .navigationTitle("Тема")
    }
}

struct CategoryLayoutPickerView: View {
    @AppStorage("categoryLayout") private var layout = "wheel"

    var body: some View {
        List {
            ForEach(["wheel", "grid", "list"], id: \.self) { option in
                Button {
                    layout = option
                } label: {
                    HStack {
                        Image(systemName: iconName(option))
                            .frame(width: 28)
                            .foregroundStyle(Color.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(option))
                                .foregroundStyle(.primary)
                            Text(descriptionText(option))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if layout == option {
                            Image(systemName: "checkmark").foregroundStyle(Color.accent)
                        }
                    }
                }
            }
        }
        .navigationTitle("Вид категорий")
    }

    private func displayName(_ option: String) -> String {
        switch option {
        case "wheel": return "Кольцо"
        case "grid": return "Сетка"
        case "list": return "Список"
        default: return option
        }
    }

    private func descriptionText(_ option: String) -> String {
        switch option {
        case "wheel": return "Категории по кругу"
        case "grid": return "Компактная сетка иконок"
        case "list": return "Полный список с названиями"
        default: return ""
        }
    }

    private func iconName(_ option: String) -> String {
        switch option {
        case "wheel": return "circle.circle"
        case "grid": return "square.grid.2x2"
        case "list": return "list.bullet"
        default: return "questionmark"
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
