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
    @State private var selectedTab = 0
    @State private var showAssistant = false

    var body: some View {
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
    }
}
