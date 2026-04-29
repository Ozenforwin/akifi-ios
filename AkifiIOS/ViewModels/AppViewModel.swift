import Foundation

@Observable @MainActor
final class AppViewModel {
    let authManager = AuthManager()
    let currencyManager = CurrencyManager()
    let paymentManager = PaymentManager()
    let dataStore = DataStore()
    let themeManager = ThemeManager()
    /// Shared Journal view-model — survives tab switches so the Journal list
    /// and tag index are not reloaded on every return to the tab.
    let journalViewModel = JournalViewModel()

    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
    private var hasLoadedData = false

    init() {
        // Inject CurrencyManager back into DataStore so widget snapshots
        // can be written with correct FX rates.
        dataStore.currencyManager = currencyManager
    }

    func initialize() async {
        await authManager.checkSession()
        if authManager.isAuthenticated {
            await loadAfterAuth()
        }
    }

    func loadAfterAuth() async {
        guard !hasLoadedData else { return }
        hasLoadedData = true
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
        async let rates: () = currencyManager.fetchRates()
        async let premium: () = paymentManager.checkPremiumStatus()
        async let data: () = dataStore.loadAll()
        _ = await (rates, premium, data)
        // `fetchRates()` and `loadAll()` run concurrently — when rates
        // arrive after `loadAll()`'s internal `rebuildCaches()`, the
        // cached FX context inside `DataStore` is built with empty rates.
        // Re-run after both finish so balances and `amountInBase(_:)`
        // see the live FX table.
        dataStore.currencyContextDidChange()
    }
}
