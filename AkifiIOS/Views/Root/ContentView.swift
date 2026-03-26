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
    }
}

struct MainTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var selectedTab = 0
    @State private var showAssistant = false
    @State private var unlockedAchievement: Achievement?

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("Главная", systemImage: "house.fill", value: 0) {
                    HomeTabView()
                }

                Tab("Операции", systemImage: "arrow.left.arrow.right", value: 1) {
                    TransactionsTabView()
                }

                Tab("Аналитика", systemImage: "chart.bar.fill", value: 2) {
                    AnalyticsTabView()
                }

                Tab("Бюджеты", systemImage: "wallet.bifold.fill", value: 3) {
                    BudgetsTabView()
                }

                Tab("Настройки", systemImage: "gearshape.fill", value: 4) {
                    SettingsView()
                }
            }
            .tint(.green)
            .fullScreenCover(isPresented: $showAssistant) {
                AssistantView()
            }

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
