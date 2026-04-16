import SwiftUI

// MARK: - App Tab

enum AppTab: Int, CaseIterable {
    case home = 0
    case transactions = 1
    case analytics = 2
    case journal = 3
    case budgets = 4

    var screenName: String {
        switch self {
        case .home: "Home"
        case .transactions: "Transactions"
        case .analytics: "Analytics"
        case .journal: "Journal"
        case .budgets: "Budgets"
        }
    }
}

enum SheetDestination: Identifiable {
    case expense(categoryId: String?)
    case income(categoryId: String?)
    case transfer
    case receipt

    var id: String {
        switch self {
        case .expense: "expense"
        case .income: "income"
        case .transfer: "transfer"
        case .receipt: "receipt"
        }
    }
}

struct ContentView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showSplash = true

    var body: some View {
        ZStack {
            Group {
                if !showSplash && !appViewModel.authManager.isLoading {
                    if !appViewModel.authManager.isAuthenticated {
                        LoginView()
                    } else if !appViewModel.hasCompletedOnboarding {
                        OnboardingView()
                    } else {
                        MainTabView()
                    }
                }
            }

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            async let init_: () = appViewModel.initialize()
            try? await Task.sleep(for: .seconds(1.5))
            _ = await init_
            withAnimation(.easeOut(duration: 0.4)) {
                showSplash = false
            }
            // After the initial load settles, reconcile pending notifications
            // with the current subscription list. Non-blocking — runs after
            // `loadAll` has populated `dataStore.subscriptions`.
            let subs = appViewModel.dataStore.subscriptions
            Task {
                await NotificationManager.rescheduleAllReminders(subscriptions: subs)
                await scheduleWeeklyDigestIfNeeded()
            }
        }
        .onChange(of: appViewModel.authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task {
                    await appViewModel.loadAfterAuth()
                    let subs = appViewModel.dataStore.subscriptions
                    await NotificationManager.rescheduleAllReminders(subscriptions: subs)
                    await scheduleWeeklyDigestIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func scheduleWeeklyDigestIfNeeded() async {
        let dataStore = appViewModel.dataStore
        let fmt = appViewModel.currencyManager
        // Snapshot on main actor before crossing concurrency boundary.
        let transactions = dataStore.transactions
        let categories = dataStore.categories
        let budgets = dataStore.budgets
        let subscriptions = dataStore.subscriptions
        let body = InsightEngine.weeklyDigest(
            InsightEngine.Input(
                transactions: transactions,
                categories: categories,
                budgets: budgets,
                subscriptions: subscriptions,
                formatAmount: { amount in
                    MainActor.assumeIsolated { fmt.formatAmount(amount.displayAmount) }
                },
                formatAmountInCurrency: { amount, currency in
                    InsightCardsView.formatInCurrency(amount: amount, currency: currency)
                }
            )
        )
        await NotificationManager.scheduleWeeklyDigest(body: body)
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var selectedTab: AppTab = .home
    @State private var showAssistant = false
    @State private var assistantVM = AssistantViewModel()
    @State private var activeSheet: SheetDestination?
    @State private var fabSelectedCategoryId: String?
    @State private var unlockedAchievement: Achievement?
    @State private var spotlightManager = SpotlightManager()
    @State private var pendingInviteCode: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content area
            Group {
                switch selectedTab {
                case .home: HomeTabView()
                case .transactions: TransactionsTabView()
                case .analytics: AnalyticsTabView()
                case .journal: JournalTabView()
                case .budgets: BudgetsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom opaque tab bar (replaces system TabView to avoid iOS 26 liquid glass)
            CustomTabBar(selectedTab: $selectedTab, onAITap: { showAssistant = true })

            // FAB
            FABView { action in
                switch action {
                case .income(let categoryId):
                    fabSelectedCategoryId = categoryId
                    activeSheet = .income(categoryId: categoryId)
                case .expense(let categoryId):
                    fabSelectedCategoryId = categoryId
                    activeSheet = .expense(categoryId: categoryId)
                case .transfer:
                    activeSheet = .transfer
                case .receipt:
                    activeSheet = .receipt
                }
            }

            // Achievement overlay
            if let achievement = unlockedAchievement {
                LevelUpView(
                    achievementName: achievement.localizedName,
                    points: achievement.points,
                    icon: achievement.icon,
                    tier: achievement.tier.rawValue
                ) {
                    unlockedAchievement = nil
                }
                .transition(.opacity)
            }

            // Offline indicator
            if !NetworkMonitor.shared.isConnected {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                        Text(String(localized: "status.offline"))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.orange))
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: NetworkMonitor.shared.isConnected)
                .zIndex(3)
            }

            // Subscription auto-match banner (non-modal, above tab bar, below overlays)
            if let match = appViewModel.dataStore.pendingAutoMatch {
                VStack {
                    SubscriptionMatchBanner(
                        match: match,
                        onUndo: {
                            Task { await appViewModel.dataStore.undoAutoMatch() }
                        },
                        onDismiss: {
                            appViewModel.dataStore.clearPendingAutoMatch()
                        }
                    )
                    .id(match.id)
                    Spacer()
                }
                .padding(.top, 8)
                .zIndex(2)
                .animation(.easeInOut(duration: 0.25), value: appViewModel.dataStore.pendingAutoMatch)
            }

            // Spotlight onboarding overlay (must be LAST — above everything)
            SpotlightOverlayView(manager: spotlightManager)
        }
        .onPreferenceChange(SpotlightFramePreferenceKey.self) { newFrames in
            Task { @MainActor in spotlightManager.frames = newFrames }
        }
        .onChange(of: spotlightManager.currentStepIndex) { _, _ in
            if let tab = spotlightManager.requiredTab, tab != selectedTab {
                withAnimation(.easeInOut(duration: 0.3)) { selectedTab = tab }
            }
        }
        .task {
            // Defer spotlight for new users — show it after first transaction
            if !appViewModel.dataStore.transactions.isEmpty {
                try? await Task.sleep(for: .seconds(1.0))
                spotlightManager.start()
            }
        }
        .onChange(of: appViewModel.dataStore.transactions.count) { _, newCount in
            if newCount > 0 {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.0))
                    spotlightManager.start()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushNotificationTapped)) { notification in
            if let tabName = notification.userInfo?["tab"] as? String {
                withAnimation {
                    switch tabName {
                    case "home": selectedTab = .home
                    case "transactions": selectedTab = .transactions
                    case "budget", "budgets": selectedTab = .budgets
                    case "analytics": selectedTab = .analytics
                    case "journal": selectedTab = .journal
                    default: break
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .fullScreenCover(isPresented: $showAssistant) {
            AssistantView(viewModel: assistantVM) { target in
                handleNavigationTarget(target)
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .expense(let categoryId):
                    TransactionFormView(
                        categories: appViewModel.dataStore.categories,
                        accounts: appViewModel.dataStore.accounts,
                        defaultCategoryId: categoryId
                    ) {
                        await appViewModel.dataStore.loadAll()
                        fabSelectedCategoryId = nil
                    }
                case .income(let categoryId):
                    TransactionFormView(
                        categories: appViewModel.dataStore.categories,
                        accounts: appViewModel.dataStore.accounts,
                        defaultType: .income,
                        defaultCategoryId: categoryId
                    ) {
                        await appViewModel.dataStore.loadAll()
                        fabSelectedCategoryId = nil
                    }
                case .transfer:
                    TransferFormView(accounts: appViewModel.dataStore.accounts) {
                        await appViewModel.dataStore.loadAll()
                    }
                case .receipt:
                    ReceiptScannerView {
                        await appViewModel.dataStore.loadAll()
                    }
                }
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .task { await checkNewAchievements() }
        .onOpenURL { url in
            let code: String?
            if url.scheme == "akifi", url.host == "invite" {
                code = url.pathComponents.last
            } else if url.host == "akifi.pro", url.pathComponents.contains("invite") {
                code = url.pathComponents.last
            } else {
                code = nil
            }
            if let code, code != "/", code.count >= 16 {
                pendingInviteCode = code
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingInviteCode != nil },
            set: { if !$0 { pendingInviteCode = nil } }
        )) {
            AcceptInviteView(initialCode: pendingInviteCode ?? "")
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private func handleNavigationTarget(_ target: NavigationTarget) {
        switch target {
        case .transactions:
            selectedTab = .transactions
        case .budgets:
            selectedTab = .budgets
        case .savings:
            selectedTab = .budgets
        case .journal:
            selectedTab = .journal
        case .addExpense:
            activeSheet = .expense(categoryId: nil)
        case .addIncome:
            activeSheet = .income(categoryId: nil)
        }
    }

    private func checkNewAchievements() async {
        let repo = AchievementRepository()
        do {
            let userAchievements = try await repo.fetchUserAchievements()
            if let unnotified = userAchievements.first(where: { !$0.notified && $0.unlockedAt != nil }) {
                let allAchievements = try await repo.fetchAll()
                if let achievement = allAchievements.first(where: { $0.id == unnotified.achievementId }) {
                    try await repo.markNotified(id: unnotified.id)
                    withAnimation {
                        unlockedAchievement = achievement
                    }
                }
            }
        } catch {
            // Silent — achievements are non-critical
        }
    }
}

// MARK: - Custom Tab Bar (opaque, no liquid glass)

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab
    @AppStorage("hapticEnabled") private var hapticEnabled = true
    var onAITap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton("house.fill", String(localized: "tab.home"), .home)
                tabButton("arrow.left.arrow.right", String(localized: "tab.transactions"), .transactions)

                // Center AI button
                Button {
                    if hapticEnabled { HapticManager.medium() }
                    onAITap()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.aiGradientStart, .aiGradientEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 48, height: 48)
                            .shadow(color: Color.aiGradientStart.opacity(0.2), radius: 8, x: 0, y: 4)

                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .offset(y: -20)
                    .spotlight(.aiButton)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(String(localized: "tab.assistant"))

                tabButton("book.fill", String(localized: "tab.journal"), .journal)
                tabButton("wallet.bifold.fill", String(localized: "tab.budgets"), .budgets)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(_ icon: String, _ label: String, _ tab: AppTab) -> some View {
        Button {
            if hapticEnabled { HapticManager.light() }
            selectedTab = tab
            AnalyticsService.logScreen(tab.screenName)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selectedTab == tab ? Color.accent : Color(.secondaryLabel))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}
