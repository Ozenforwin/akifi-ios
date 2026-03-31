import SwiftUI

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
    @State private var selectedTab = 0
    @State private var showAssistant = false
    @State private var assistantVM = AssistantViewModel()
    @State private var showAddTransaction = false
    @State private var showAddTransfer = false
    @State private var showAddIncome = false
    @State private var showReceiptScanner = false
    @State private var fabSelectedCategoryId: String?
    @State private var unlockedAchievement: Achievement?
    @State private var spotlightManager = SpotlightManager()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content area
            Group {
                switch selectedTab {
                case 0: HomeTabView()
                case 1: TransactionsTabView()
                case 2: AnalyticsTabView()
                case 3: BudgetsTabView()
                default: HomeTabView()
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
                    showAddIncome = true
                case .expense(let categoryId):
                    fabSelectedCategoryId = categoryId
                    showAddTransaction = true
                case .transfer:
                    showAddTransfer = true
                case .receipt:
                    showReceiptScanner = true
                }
            }

            // Achievement overlay
            if let achievement = unlockedAchievement {
                LevelUpView(
                    achievementName: achievement.nameRu,
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
        .onPreferenceChange(SpotlightFramePreferenceKey.self) { spotlightManager.frames = $0 }
        .onChange(of: spotlightManager.currentStepIndex) { _, _ in
            if let tab = spotlightManager.requiredTab, tab != selectedTab {
                withAnimation(.easeInOut(duration: 0.3)) { selectedTab = tab }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                spotlightManager.start()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .fullScreenCover(isPresented: $showAssistant) {
            AssistantView(viewModel: assistantVM) { target in
                handleNavigationTarget(target)
            }
        }
        .sheet(isPresented: $showAddTransaction) {
            TransactionFormView(
                categories: appViewModel.dataStore.categories,
                accounts: appViewModel.dataStore.accounts,
                defaultCategoryId: fabSelectedCategoryId
            ) {
                await appViewModel.dataStore.loadAll()
                fabSelectedCategoryId = nil
            }
        }
        .sheet(isPresented: $showAddIncome) {
            TransactionFormView(
                categories: appViewModel.dataStore.categories,
                accounts: appViewModel.dataStore.accounts,
                defaultType: .income,
                defaultCategoryId: fabSelectedCategoryId
            ) {
                await appViewModel.dataStore.loadAll()
                fabSelectedCategoryId = nil
            }
        }
        .sheet(isPresented: $showAddTransfer) {
            TransferFormView(accounts: appViewModel.dataStore.accounts) {
                await appViewModel.dataStore.loadAll()
            }
        }
        .sheet(isPresented: $showReceiptScanner) {
            ReceiptScannerView {
                await appViewModel.dataStore.loadAll()
            }
        }
        .task { await checkNewAchievements() }
    }

    private func handleNavigationTarget(_ target: NavigationTarget) {
        switch target {
        case .transactions:
            selectedTab = 1
        case .budgets:
            selectedTab = 3
        case .savings:
            selectedTab = 3
        case .addExpense:
            showAddTransaction = true
        case .addIncome:
            showAddIncome = true
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
    @Binding var selectedTab: Int
    @AppStorage("hapticEnabled") private var hapticEnabled = true
    var onAITap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton("house.fill", String(localized: "tab.home"), 0)
                tabButton("arrow.left.arrow.right", String(localized: "tab.transactions"), 1)

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

                tabButton("chart.bar.fill", String(localized: "tab.analytics"), 2)
                tabButton("wallet.bifold.fill", String(localized: "tab.budgets"), 3)
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

    private func tabButton(_ icon: String, _ label: String, _ tag: Int) -> some View {
        Button {
            if hapticEnabled { HapticManager.light() }
            selectedTab = tag
            AnalyticsService.logScreen(["Home", "Transactions", "Analytics", "Budgets"][tag])
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selectedTab == tag ? Color.accent : Color(.secondaryLabel))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}
