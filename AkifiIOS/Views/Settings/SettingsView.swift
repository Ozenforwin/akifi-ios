import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var showDeleteConfirmation = false
    @State private var showReceiptScanner = false
    @State private var showDeleteFinalConfirmation = false
    @State private var deleteError: String?

    private var currentLanguageName: String {
        switch appLanguage {
        case "ru": return "Русский"
        case "en": return "English"
        case "es": return "Español"
        default: return String(localized: "settings.language.system")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Profile header
                Section {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 3)
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

                Section(header: Text(String(localized: "settings.section.general"))) {
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

                Section(header: Text(String(localized: "settings.section.settings"))) {
                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        SettingsRow(icon: "dollarsign.circle.fill", color: .green, title: String(localized: "settings.currency"), value: appViewModel.currencyManager.selectedCurrency.symbol)
                    }

                    NavigationLink {
                        LanguagePickerView()
                    } label: {
                        SettingsRow(icon: "globe", color: .blue, title: String(localized: "settings.language"), value: currentLanguageName)
                    }

                    NavigationLink {
                        AISettingsView()
                    } label: {
                        SettingsRow(icon: "sparkles", color: .purple, title: String(localized: "settings.aiAssistant"))
                    }

                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        SettingsRow(icon: "bell.fill", color: .orange, title: String(localized: "settings.notifications"))
                    }

                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        SettingsRow(icon: "paintbrush.fill", color: .indigo, title: String(localized: "settings.theme"), value: appViewModel.themeManager.themeName)
                    }

                    NavigationLink {
                        CategoryLayoutPickerView()
                    } label: {
                        SettingsRow(icon: "square.grid.2x2", color: .teal, title: String(localized: "settings.categoryLayout"))
                    }

                    HapticToggleRow()

                    Button {
                        UserDefaults.standard.set(false, forKey: "spotlight_completed")
                    } label: {
                        SettingsRow(icon: "lightbulb.fill", color: .yellow, title: String(localized: "settings.resetTutorial"))
                    }
                }

                Section(header: Text(String(localized: "settings.section.accounts"))) {
                    NavigationLink {
                        AcceptInviteView()
                    } label: {
                        SettingsRow(icon: "person.badge.plus", color: .blue, title: String(localized: "invite.title"))
                    }
                }

                Section(header: Text(String(localized: "settings.section.finance"))) {
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

                Section(header: Text(String(localized: "settings.section.data"))) {
                    NavigationLink {
                        ExportView()
                    } label: {
                        SettingsRow(icon: "square.and.arrow.up", color: .blue, title: String(localized: "settings.export"))
                    }

                    NavigationLink {
                        BankImportView()
                    } label: {
                        SettingsRow(icon: "square.and.arrow.down", color: .green, title: String(localized: "settings.import"))
                    }

                    Button {
                        showReceiptScanner = true
                    } label: {
                        SettingsRow(icon: "doc.text.viewfinder", color: .orange, title: String(localized: "settings.scanReceipt"))
                    }
                }

                Section(String(localized: "settings.about")) {
                    HStack {
                        Text(String(localized: "common.version"))
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }

                    ShareLink(
                        item: URL(string: "https://apps.apple.com/app/akifi")!,
                        subject: Text("Akifi"),
                        message: Text(String(localized: "settings.shareMessage"))
                    ) {
                        SettingsRow(icon: "square.and.arrow.up.fill", color: .purple, title: String(localized: "settings.share"))
                    }

                    Link(destination: URL(string: "https://akifi.ru/privacy")!) {
                        SettingsRow(icon: "hand.raised.fill", color: .blue, title: String(localized: "settings.privacy"))
                    }

                    Link(destination: URL(string: "https://akifi.ru/terms")!) {
                        SettingsRow(icon: "doc.text.fill", color: .gray, title: String(localized: "settings.terms"))
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

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(String(localized: "settings.deleteAccount"), systemImage: "person.crop.circle.badge.minus")
                    }
                }

                Color.clear.frame(height: 120)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .alert(String(localized: "settings.deleteAccount.title"), isPresented: $showDeleteConfirmation) {
                Button(String(localized: "common.cancel"), role: .cancel) {}
                Button(String(localized: "settings.deleteAccount.confirm"), role: .destructive) {
                    showDeleteFinalConfirmation = true
                }
            } message: {
                Text(String(localized: "settings.deleteAccount.warning"))
            }
            .alert(String(localized: "settings.deleteAccount.finalTitle"), isPresented: $showDeleteFinalConfirmation) {
                Button(String(localized: "common.cancel"), role: .cancel) {}
                Button(String(localized: "settings.deleteAccount.finalConfirm"), role: .destructive) {
                    Task {
                        do {
                            try await appViewModel.authManager.deleteAccount()
                        } catch {
                            deleteError = error.localizedDescription
                        }
                    }
                }
            } message: {
                Text(String(localized: "settings.deleteAccount.finalWarning"))
            }
            .alert("Error", isPresented: .init(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .sheet(isPresented: $showReceiptScanner) {
                ReceiptScannerView {
                    await appViewModel.dataStore.loadAll()
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
                    AnalyticsService.logChangeCurrency(to: currency.rawValue)
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

struct HapticToggleRow: View {
    @AppStorage("hapticEnabled") private var hapticEnabled = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.pink)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Toggle(String(localized: "settings.haptic"), isOn: $hapticEnabled)
        }
    }
}

struct LanguagePickerView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"

    private let languages: [(id: String, name: String, flag: String)] = [
        ("system", "System", "🌐"),
        ("ru", "Русский", "🇷🇺"),
        ("en", "English", "🇺🇸"),
        ("es", "Español", "🇪🇸"),
    ]

    var body: some View {
        List {
            ForEach(languages, id: \.id) { lang in
                Button {
                    appLanguage = lang.id
                    applyLanguage(lang.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(lang.flag)
                            .font(.title2)
                        Text(lang.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if appLanguage == lang.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
            }

            Section {
                Text(String(localized: "settings.language.restart"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "settings.language"))
    }

    private func applyLanguage(_ code: String) {
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        AnalyticsService.logChangeLanguage(to: code)
    }
}
