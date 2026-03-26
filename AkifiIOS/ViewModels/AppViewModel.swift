import Foundation

@Observable @MainActor
final class AppViewModel {
    let authManager = AuthManager()
    let currencyManager = CurrencyManager()
    let paymentManager = PaymentManager()
    let dataStore = DataStore()

    var hasCompletedOnboarding = false

    func initialize() async {
        await authManager.checkSession()
        if authManager.isAuthenticated {
            await loadAfterAuth()
        }
    }

    func loadAfterAuth() async {
        async let rates: () = currencyManager.fetchRates()
        async let premium: () = paymentManager.checkPremiumStatus()
        async let data: () = dataStore.loadAll()
        _ = await (rates, premium, data)
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
    }
}
