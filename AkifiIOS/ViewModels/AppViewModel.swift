import Foundation

@Observable @MainActor
final class AppViewModel {
    let authManager = AuthManager()
    let currencyManager = CurrencyManager()
    let paymentManager = PaymentManager()

    var hasCompletedOnboarding = false

    func initialize() async {
        await authManager.checkSession()
        if authManager.isAuthenticated {
            await currencyManager.fetchRates()
            await paymentManager.checkPremiumStatus()
            hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
        }
    }
}
