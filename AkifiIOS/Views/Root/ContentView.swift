import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        Group {
            if appViewModel.authManager.isLoading {
                SplashView()
            } else if !appViewModel.authManager.isAuthenticated {
                LoginView()
            } else if !appViewModel.hasCompletedOnboarding {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task {
            await appViewModel.initialize()
        }
        .onChange(of: appViewModel.authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task { await appViewModel.loadAfterAuth() }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var selectedTab = 0
    @State private var showAssistant = false
    @State private var showAddTransaction = false
    @State private var showAddTransfer = false
    @State private var showAddIncome = false
    @State private var unlockedAchievement: Achievement?

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(String(localized: "tabs.home"), systemImage: "house.fill", value: 0) {
                    HomeTabView()
                }

                Tab(String(localized: "tabs.transactions"), systemImage: "arrow.left.arrow.right", value: 1) {
                    TransactionsTabView()
                }

                // Spacer tab for center AI button
                Tab("", systemImage: "sparkles", value: 99) {
                    Color.clear
                }
                .hidden()

                Tab(String(localized: "tabs.analytics"), systemImage: "chart.bar.fill", value: 2) {
                    AnalyticsTabView()
                }

                Tab(String(localized: "tabs.budgets"), systemImage: "wallet.bifold.fill", value: 3) {
                    BudgetsTabView()
                }
            }
            .tint(Color.accent)

            // Center AI button
            VStack {
                Spacer()
                Button {
                    showAssistant = true
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
                            .frame(width: 56, height: 56)
                            .shadow(color: Color.aiGradientStart.opacity(0.25), radius: 8, x: 0, y: 4)

                        Image(systemName: "sparkles")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 4)
                    }
                }
                .buttonStyle(.plain)
                .offset(y: -5)
                .padding(.bottom, 28)
            }

            // FAB
            FABView { action in
                switch action {
                case .income:
                    showAddIncome = true
                case .expense:
                    showAddTransaction = true
                case .transfer:
                    showAddTransfer = true
                case .receipt:
                    break
                }
            }

            // Achievement overlay
            if let achievement = unlockedAchievement {
                LevelUpView(
                    achievementName: achievement.nameRu,
                    points: achievement.points,
                    icon: achievement.icon
                ) {
                    unlockedAchievement = nil
                }
                .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $showAssistant) {
            AssistantView()
        }
        .sheet(isPresented: $showAddTransaction) {
            TransactionFormView(
                categories: appViewModel.dataStore.categories,
                accounts: appViewModel.dataStore.accounts
            ) {
                await appViewModel.dataStore.loadAll()
            }
        }
        .sheet(isPresented: $showAddIncome) {
            TransactionFormView(
                categories: appViewModel.dataStore.categories,
                accounts: appViewModel.dataStore.accounts,
                defaultType: .income
            ) {
                await appViewModel.dataStore.loadAll()
            }
        }
        .sheet(isPresented: $showAddTransfer) {
            TransferFormView(accounts: appViewModel.dataStore.accounts) {
                await appViewModel.dataStore.loadAll()
            }
        }
        .task { await checkNewAchievements() }
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
