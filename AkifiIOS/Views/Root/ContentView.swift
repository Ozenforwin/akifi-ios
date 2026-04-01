import SwiftUI

// MARK: - App Tab

enum AppTab: Int, CaseIterable {
    case home = 0
    case transactions = 1
    case analytics = 2
    case budgets = 3

    var screenName: String {
        switch self {
        case .home: "Home"
        case .transactions: "Transactions"
        case .analytics: "Analytics"
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
        }
        .onChange(of: appViewModel.authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task { await appViewModel.loadAfterAuth() }
            }
        }
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

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content area
            Group {
                switch selectedTab {
                case .home: HomeTabView()
                case .transactions: TransactionsTabView()
                case .analytics: AnalyticsTabView()
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
        .ignoresSafeArea(edges: .bottom)
        .fullScreenCover(isPresented: $showAssistant) {
            AssistantView(viewModel: assistantVM) { target in
                handleNavigationTarget(target)
            }
        }
        .sheet(item: $activeSheet) { sheet in
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
        .task { await checkNewAchievements() }
    }

    private func handleNavigationTarget(_ target: NavigationTarget) {
        switch target {
        case .transactions:
            selectedTab = .transactions
        case .budgets:
            selectedTab = .budgets
        case .savings:
            selectedTab = .budgets
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
                            .frame(width: 52, height: 52)
                            .shadow(color: Color.aiGradientStart.opacity(0.2), radius: 8, x: 0, y: 4)

                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .offset(y: -22)
                    .spotlight(.aiButton)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(String(localized: "tab.assistant"))

                tabButton("chart.bar.fill", String(localized: "tab.analytics"), .analytics)
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
