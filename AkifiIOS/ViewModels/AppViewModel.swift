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

        // The splash stays up until this returns, so nothing here may wait
        // on the network indefinitely. Offline cold start (valid keychain
        // session, no connectivity) reaches this path since the auth
        // fallback shipped — before that it bounced to LoginView and this
        // never ran without a network. Rates fall back to their cache,
        // premium to non-premium (rechecked on next launch), loadAll
        // short-circuits to the offline cache internally.
        await NetworkMonitor.shared.waitForFirstUpdate()
        let online = NetworkMonitor.shared.isConnected

        async let data: () = dataStore.loadAll()
        if online {
            // Hard ceilings: SDK-level retries (rates 2 attempts, Supabase
            // interceptor 2 retries with backoff) stack up on a flaky
            // connection; the splash must not absorb that.
            let currencyManager = self.currencyManager
            let paymentManager = self.paymentManager
            async let rates: () = { try? await withTimeout(seconds: 8) { await currencyManager.fetchRates() } }()
            async let premium: () = { try? await withTimeout(seconds: 8) { await paymentManager.checkPremiumStatus() } }()
            _ = await (rates, premium)
        }
        _ = await data

        // `fetchRates()` and `loadAll()` run concurrently — when rates
        // arrive after `loadAll()`'s internal `rebuildCaches()`, the
        // cached FX context inside `DataStore` is built with empty rates.
        // Re-run after both finish so balances and `amountInBase(_:)`
        // see the live FX table.
        dataStore.currencyContextDidChange()
    }
}
