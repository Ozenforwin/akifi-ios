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
        case "ru": return String(localized: "language.russian")
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
                        StatBadge(value: "\(appViewModel.dataStore.accounts.count)", label: String(localized: "stats.accounts"))
                        StatBadge(value: "\(appViewModel.dataStore.transactions.count)", label: String(localized: "stats.transactions"))
                        StatBadge(value: "\(appViewModel.dataStore.categories.count)", label: String(localized: "stats.categories"))
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
                        BaseCurrencyPickerView()
                    } label: {
                        SettingsRow(icon: "banknote.fill", color: .mint, title: String(localized: "settings.baseCurrency"), value: appViewModel.currencyManager.dataCurrency.symbol)
                    }

                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        SettingsRow(icon: "dollarsign.circle.fill", color: .green, title: String(localized: "settings.displayCurrency"), value: appViewModel.currencyManager.selectedCurrency.symbol)
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
                        item: URL(string: "https://apps.apple.com/tj/app/akifi/id6761304897")!,
                        subject: Text("Akifi"),
                        message: Text(String(localized: "settings.shareMessage"))
                    ) {
                        SettingsRow(icon: "square.and.arrow.up.fill", color: .purple, title: String(localized: "settings.share"))
                    }

                    Link(destination: URL(string: "https://akifi.pro/privacy")!) {
                        SettingsRow(icon: "hand.raised.fill", color: .blue, title: String(localized: "settings.privacy"))
                    }

                    Link(destination: URL(string: "https://akifi.pro/terms")!) {
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
                .presentationBackground(.ultraThinMaterial)
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
                    Label(String(localized: "theme.system"), systemImage: "gear")
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
                    Label(String(localized: "theme.light"), systemImage: "sun.max.fill")
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
                    Label(String(localized: "theme.dark"), systemImage: "moon.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    if appViewModel.themeManager.selectedScheme == .dark {
                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings.theme"))
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
        .navigationTitle(String(localized: "settings.categoryLayout"))
    }

    private func displayName(_ option: String) -> String {
        switch option {
        case "wheel": return String(localized: "categoryLayout.wheel")
        case "grid": return String(localized: "categoryLayout.grid")
        case "list": return String(localized: "categoryLayout.list")
        default: return option
        }
    }

    private func descriptionText(_ option: String) -> String {
        switch option {
        case "wheel": return String(localized: "categoryLayout.wheel.description")
        case "grid": return String(localized: "categoryLayout.grid.description")
        case "list": return String(localized: "categoryLayout.list.description")
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

struct BaseCurrencyPickerView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showConfirmAlert = false
    @State private var pendingCurrency: CurrencyCode?

    var body: some View {
        List {
            Section {
                ForEach(CurrencyCode.allCases, id: \.self) { currency in
                    Button {
                        if currency != appViewModel.currencyManager.dataCurrency {
                            pendingCurrency = currency
                            showConfirmAlert = true
                        }
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
                            if appViewModel.currencyManager.dataCurrency == currency {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section {
                Text(String(localized: "settings.baseCurrency.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "settings.baseCurrency"))
        .alert(String(localized: "settings.baseCurrency.confirmTitle"), isPresented: $showConfirmAlert) {
            Button(String(localized: "settings.baseCurrency.change")) {
                if let currency = pendingCurrency {
                    appViewModel.currencyManager.dataCurrency = currency
                    appViewModel.currencyManager.selectedCurrency = currency
                }
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.baseCurrency.confirmMessage"))
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
        .navigationTitle(String(localized: "settings.currency"))
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
    @State private var showRestartAlert = false

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
                    let oldLang = appLanguage
                    appLanguage = lang.id
                    applyLanguage(lang.id)
                    if oldLang != lang.id {
                        showRestartAlert = true
                    }
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
        }
        .navigationTitle(String(localized: "settings.language"))
        .alert(String(localized: "settings.language.restartTitle"), isPresented: $showRestartAlert) {
            Button(String(localized: "settings.language.later"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.language.restartMessage"))
        }
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
