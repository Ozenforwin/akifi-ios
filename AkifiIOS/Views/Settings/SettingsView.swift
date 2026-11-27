import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var showDeleteConfirmation = false
    @State private var showReceiptScanner = false
    @State private var showDeleteFinalConfirmation = false
    @State private var deleteError: String?
    @State private var showSignOutPendingWarning = false

    private var currentLanguageName: String {
        switch appLanguage {
        case "ru": return String(localized: "language.russian")
        case "en": return "English"
        case "es": return "Español"
        default: return String(localized: "settings.language.system")
        }
    }

    /// Pushed onto Home's navigation stack (1.6): the stack, the back
    /// button and the bar belong to Home — this screen brings its list.
    var body: some View {
        List {
            // Profile header + stats — the account card at the top of
            // the system Settings app.
            Section {
                SettingsProfileHeader(
                    avatarUrl: appViewModel.dataStore.profile?.avatarUrl,
                    name: appViewModel.dataStore.profile?.fullName
                        ?? appViewModel.authManager.currentUser?.email ?? "User",
                    email: appViewModel.authManager.currentUser?.email
                        ?? appViewModel.dataStore.profile?.email
                )

                HStack(spacing: 0) {
                    StatBadge(value: "\(appViewModel.dataStore.accounts.count)", label: String(localized: "stats.accounts"))
                    Divider()
                    StatBadge(value: "\(appViewModel.dataStore.transactions.count)", label: String(localized: "stats.transactions"))
                    Divider()
                    StatBadge(value: "\(appViewModel.dataStore.displayCategories.count)", label: String(localized: "stats.categories"))
                }
                .padding(.vertical, 4)
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

                // Active-currencies row — controls which currencies
                // appear in the inline `ActiveCurrencyPicker` used
                // by transaction / account / budget forms. Distinct
                // from base/display currency above (which control
                // analytics + home screen).
                NavigationLink {
                    ManageActiveCurrenciesView()
                } label: {
                    SettingsRow(
                        icon: "list.bullet",
                        color: .green,
                        title: String(localized: "settings.activeCurrencies.title"),
                        value: String(
                            format: String(localized: "settings.activeCurrencies.row %lld"),
                            UserCurrencyPreferences.shared.activeCodes.count
                        )
                    )
                }

                // Display-currency picker intentionally NOT duplicated
                // here — the Home-screen currency switcher is the
                // primary control and having both made "Base" vs
                // "Display" indistinguishable in the user's head.

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
                    SettingsRow(icon: "bell.fill", color: .red, title: String(localized: "settings.notifications"))
                }

                NavigationLink {
                    ThemePickerView()
                } label: {
                    SettingsRow(icon: "paintbrush.fill", color: .indigo, title: String(localized: "settings.theme"), value: appViewModel.themeManager.themeName)
                }

                NavigationLink {
                    CategoryLayoutPickerView()
                } label: {
                    SettingsRow(icon: "square.grid.2x2.fill", color: .teal, title: String(localized: "settings.categoryLayout"))
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

                NavigationLink {
                    PaymentDefaultsView()
                } label: {
                    SettingsRow(icon: "creditcard.fill", color: .blue, title: String(localized: "settings.paymentDefaults"))
                }
            }

            Section(header: Text(String(localized: "settings.section.finance"))) {
                NavigationLink {
                    AchievementsView()
                } label: {
                    SettingsRow(icon: "trophy.fill", color: .yellow, title: String(localized: "achievements.title"))
                }

                // Net Worth, Assets, Liabilities, Savings, Deposits,
                // Challenges and Reports all live under "Beta features"
                // until they graduate — single entry, one BETA badge at
                // the door, consistent expectation-setting for the user.
                NavigationLink {
                    BetaFeaturesView()
                } label: {
                    SettingsRow(
                        icon: "flask.fill",
                        color: .orange,
                        title: String(localized: "settings.beta.title"),
                        badge: "BETA"
                    )
                }
            }

            Section(header: Text(String(localized: "settings.section.data"))) {
                NavigationLink {
                    CurrencyReconciliationView()
                } label: {
                    SettingsRow(
                        icon: "dollarsign.arrow.circlepath",
                        color: .mint,
                        title: String(localized: "settings.currencyReconciliation")
                    )
                }
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
                LabeledContent(
                    String(localized: "common.version"),
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                )

                ShareLink(
                    item: URL(string: "https://apps.apple.com/tj/app/akifi/id6761304897")!,
                    subject: Text("Akifi"),
                    message: Text(String(localized: "settings.shareMessage"))
                ) {
                    SettingsRow(icon: "square.and.arrow.up.fill", color: .purple, title: String(localized: "settings.share"))
                }

                Link(destination: URL(string: "https://akifi.pro/privacy")!) {
                    SettingsRow(icon: "hand.raised.fill", color: .blue, title: String(localized: "settings.privacy"), isExternalLink: true)
                }

                Link(destination: URL(string: "https://akifi.pro/terms")!) {
                    SettingsRow(icon: "doc.text.fill", color: .gray, title: String(localized: "settings.terms"), isExternalLink: true)
                }
            }

            // Offline writes that gave up after repeated replay failures.
            // Hidden entirely in the happy path.
            if !appViewModel.dataStore.offlineQueue.deadLetterOperations.isEmpty {
                Section {
                    SettingsRow(
                        icon: "exclamationmark.icloud.fill",
                        color: .red,
                        title: String(
                            format: String(localized: "offline.syncFailed"),
                            appViewModel.dataStore.offlineQueue.deadLetterOperations.count
                        )
                    )
                    HStack {
                        Button(String(localized: "offline.syncFailed.retry")) {
                            let dataStore = appViewModel.dataStore
                            Task { await dataStore.retryUnsyncedOperations() }
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button(String(localized: "offline.syncFailed.discard"), role: .destructive) {
                            let dataStore = appViewModel.dataStore
                            Task { await dataStore.discardUnsyncedOperations() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    // Sign-out wipes the offline cache including queued
                    // and refused writes — never silently discard
                    // unsynced entries (Y6).
                    if appViewModel.dataStore.offlineQueue.hasUnsynced {
                        showSignOutPendingWarning = true
                    } else {
                        Task { await appViewModel.signOut() }
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
        }
        .listStyle(.insetGrouped)
        .akifiFloatingButtonClearance()
        .alert(String(localized: "signout.pendingWarning.title"), isPresented: $showSignOutPendingWarning) {
            Button(String(localized: "common.cancel"), role: .cancel) {}
            Button(String(localized: "auth.signOut"), role: .destructive) {
                Task { await appViewModel.signOut() }
            }
        } message: {
            Text(String(
                format: String(localized: "signout.pendingWarning"),
                appViewModel.dataStore.offlineQueue.unsyncedCount
            ))
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
                        try await appViewModel.deleteAccount()
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(String(localized: "settings.deleteAccount.finalWarning"))
        }
        .alert(String(localized: "common.error"), isPresented: .init(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button(String(localized: "common.ok")) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showReceiptScanner) {
            ReceiptScannerView {
                await appViewModel.dataStore.loadAll()
            }
        }
        .navigationTitle(String(localized: "common.settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Components

/// Top row of Settings: photo, name and email, left-aligned like the
/// account row of the system Settings app.
private struct SettingsProfileHeader: View {
    let avatarUrl: String?
    let name: String
    let email: String?

    @ScaledMetric(relativeTo: .title2) private var avatarSize: CGFloat = 60

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let avatarUrl, let url = URL(string: avatarUrl) {
                    CachedAsyncImage(url: url) { placeholder }
                } else {
                    placeholder
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let email, email != name {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
    }
}

/// SF Symbol on a rounded colour tile — the icon of a system Settings
/// row. Scales with Dynamic Type; hidden from VoiceOver (the row's title
/// speaks for it).
struct SettingsIconTile: View {
    let systemName: String
    let color: Color

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String? = nil
    var badge: String? = nil
    /// Opens a web page: a trailing `arrow.up.forward` marks it.
    var isExternalLink = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemName: icon, color: color)

            // `Color.primary`, not the hierarchical `.primary`: inside a
            // Button / Link / ShareLink the latter resolves to the tint.
            Text(title)
                .foregroundStyle(Color.primary)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.orange)
            }

            if value != nil || isExternalLink {
                Spacer(minLength: 8)
            }

            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }

            if isExternalLink {
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
        .navigationBarTitleDisplayMode(.inline)
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
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var pendingCurrency: Currency?
    @State private var showCurrencyPicker = false
    /// Buffer that the searchable picker writes back into. We don't bind
    /// directly to `appViewModel.currencyManager.dataCurrency` because
    /// a base-currency change has to go through a confirm alert first
    /// (it triggers an FX-context rebuild + UI refresh in DataStore).
    @State private var pickerSelection: Currency = .rub

    var body: some View {
        List {
            Section {
                Button {
                    pickerSelection = appViewModel.currencyManager.dataCurrency
                    showCurrencyPicker = true
                } label: {
                    HStack {
                        Text(String(localized: "settings.baseCurrency"))
                            .foregroundStyle(.primary)
                        Spacer()
                        let cur = appViewModel.currencyManager.dataCurrency
                        Text("\(cur.symbol)  \(cur.code)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityLabel(String(localized: "settings.baseCurrency"))
            } footer: {
                Text(String(localized: "settings.baseCurrency.hint"))
            }
        }
        .navigationTitle(String(localized: "settings.baseCurrency"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCurrencyPicker, onDismiss: {
            // The picker calls `dismiss()` after a tap, so by the time
            // `onDismiss` fires the new value is already in
            // `pickerSelection`. We compare to the live data currency
            // and only confirm if the user actually changed it.
            if pickerSelection != appViewModel.currencyManager.dataCurrency {
                pendingCurrency = pickerSelection
                showConfirmAlert = true
            }
        }) {
            CurrencyPickerView(selection: $pickerSelection)
        }
        .alert(String(localized: "settings.baseCurrency.confirmTitle"), isPresented: $showConfirmAlert) {
            Button(String(localized: "settings.baseCurrency.change")) {
                if let currency = pendingCurrency {
                    appViewModel.currencyManager.dataCurrency = currency
                    appViewModel.currencyManager.selectedCurrency = currency
                    // The cached FX context inside DataStore is keyed off
                    // `baseCurrencyCode`; re-derive balances so analytics
                    // pick up the new base immediately.
                    appViewModel.dataStore.currencyContextDidChange()
                }
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.baseCurrency.confirmMessage"))
        }
    }
}

struct HapticToggleRow: View {
    @AppStorage("hapticEnabled") private var hapticEnabled = true

    var body: some View {
        Toggle(isOn: $hapticEnabled) {
            HStack(spacing: 12) {
                SettingsIconTile(systemName: "hand.tap.fill", color: .pink)
                Text(String(localized: "settings.haptic"))
            }
        }
    }
}

struct LanguagePickerView: View {
    @Environment(AppViewModel.self) private var appViewModel
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
                        Task { await rescheduleLocalizedNotifications() }
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
        .navigationBarTitleDisplayMode(.inline)
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

    /// When the user changes language, locally-scheduled notifications still
    /// carry the old-language body. Reschedule them to pick up new translations.
    /// Also syncs the language preference to the server so backend-driven push
    /// (smart-notifications, send-weekly-digest) renders in the new language.
    private func rescheduleLocalizedNotifications() async {
        let dataStore = appViewModel.dataStore
        let fmt = appViewModel.currencyManager
        let subs = dataStore.subscriptions

        // Backend sync — best effort; silently ignored when offline.
        let serverLang: String = {
            if appLanguage != "system" { return appLanguage }
            return Locale.current.language.languageCode?.identifier ?? "ru"
        }()
        try? await ProfileRepository().updatePreferredLanguage(serverLang)

        _ = await NotificationManager.rescheduleAllReminders(subscriptions: subs)

        let transactions = dataStore.transactions
        let categories = dataStore.categories
        let budgets = dataStore.budgets
        let ctx = dataStore.currencyContext
        let body = InsightEngine.weeklyDigest(
            InsightEngine.Input(
                transactions: transactions,
                categories: categories,
                budgets: budgets,
                subscriptions: subs,
                formatAmount: { amount in
                    MainActor.assumeIsolated { fmt.formatAmount(amount.displayAmount) }
                },
                formatAmountInCurrency: { amount, currency in
                    InsightCardsView.formatInCurrency(amount: amount, currency: currency)
                },
                accountsById: ctx.accountsById,
                fxRates: ctx.fxRates,
                baseCode: ctx.baseCode,
                externalSpendByBudget: dataStore.externalSpendByBudget
            )
        )
        await NotificationManager.syncWeeklyDigest(
            body: body,
            userId: appViewModel.authManager.currentUser?.id.uuidString.lowercased()
        )
    }
}
