import Foundation

@Observable @MainActor
final class AppViewModel {
    let authManager = AuthManager()
    let currencyManager = CurrencyManager()
    let paymentManager = PaymentManager()
    let dataStore = DataStore()
    let themeManager = ThemeManager()

    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")

    func initialize() async {
        await authManager.checkSession()
        if authManager.isAuthenticated {
            await loadAfterAuth()
        }
    }

    func loadAfterAuth() async {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
        async let rates: () = currencyManager.fetchRates()
        async let premium: () = paymentManager.checkPremiumStatus()
        async let data: () = dataStore.loadAll()
        _ = await (rates, premium, data)
    }
}
