import Foundation
import UserNotifications
import WidgetKit

@Observable @MainActor
final class AppViewModel {
    let authManager = AuthManager()
    let currencyManager = CurrencyManager()
    let paymentManager = PaymentManager()
    let dataStore: DataStore
    let themeManager = ThemeManager()
    /// Shared Journal view-model — survives tab switches so the Journal list
    /// and tag index are not reloaded on every return to the tab.
    let journalViewModel = JournalViewModel()
    /// «Долги» (1.6.0): summary, movements, reminders — shared by Home,
    /// Net Worth and the Debts screens.
    let debts = DebtsStore()

    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
    private(set) var hasLoadedData = false

    /// The network refresh started by `loadAfterAuth()`. When cached data
    /// exists it runs behind the already-visible UI (P3).
    @ObservationIgnored private var backgroundRefresh: Task<Void, Never>?

    /// Device-level side effects of a session ending / starting, as
    /// closures so the sign-out reset is testable without Firebase,
    /// WidgetKit or a Supabase session.
    struct SessionEffects {
        /// Detach this device's FCM token from the profile row. Needs the
        /// session — runs before it is removed. Bounded, best effort.
        var unregisterPushToken: @MainActor () async -> Void
        /// Attach the device's FCM token to the signed-in user's profile.
        var registerPushToken: @MainActor () async -> Void
        /// Wipe what lives outside the app sandbox's data cache: the widget
        /// snapshot, scheduled / delivered local notifications, the FCM
        /// token itself (rotated, so a copy left on the old profile dies).
        var clearDeviceState: @MainActor () -> Void

        static var live: SessionEffects {
            SessionEffects(
                unregisterPushToken: {
                    do {
                        try await withTimeout(seconds: 4) {
                            try await NotificationRepository().unregisterFCMToken()
                        }
                    } catch {
                        AppLogger.notifications.info("FCM unregister on sign-out failed: \(error.localizedDescription)")
                    }
                },
                registerPushToken: {
                    await NotificationRepository().registerCurrentDeviceToken()
                },
                clearDeviceState: {
                    SharedSnapshotStore.clear()
                    WidgetCenter.shared.reloadAllTimelines()
                    let center = UNUserNotificationCenter.current()
                    center.removeAllPendingNotificationRequests()
                    center.removeAllDeliveredNotifications()
                    NotificationRepository.rotateDeviceToken()
                }
            )
        }
    }

    @ObservationIgnored var sessionEffects: SessionEffects = .live

    init(dataStore: DataStore? = nil) {
        self.dataStore = dataStore ?? DataStore()
        // Inject CurrencyManager back into DataStore so widget snapshots
        // can be written with correct FX rates.
        self.dataStore.currencyManager = currencyManager
        // The SDK ended the session (refresh token dead): wipe the previous
        // user's data but keep the owner-tagged queue — if the same user
        // signs back in, their unsynced entries still replay.
        authManager.onSessionEnded = { [weak self] in
            self?.resetForSignOut(preserveQueue: true)
        }
        // A load or write found no session at all while online: the SDK
        // dropped it and the event was missed — same forced sign-out (Y1).
        self.dataStore.onSessionMissing = { [weak self] in
            self?.authManager.sessionVanished()
        }
        // Siri / Shortcuts write through this instance's data store, never
        // a second one (see QuickEntryHost).
        QuickEntryHost.shared.attach(self)
    }

    // MARK: - Incoming URLs

    /// Navigation / invite link waiting for the signed-in UI
    /// (`MainTabView` consumes and clears it). Survives the login screen,
    /// so an invite tapped while signed out opens after sign-in — still
    /// behind the confirmation screen (S2).
    var pendingDeepLink: DeepLink?

    /// Single entry point for every URL the app is opened with.
    func open(_ url: URL) {
        // akifi://quick-add?… waits in QuickEntryInbox for the signed-in UI.
        if QuickEntryInbox.shared.open(url) { return }
        guard let link = DeepLink.parse(url) else { return }
        switch link {
        case .authCallback(let callback):
            Task { await authManager.handleAuthCallback(callback) }
        case .tab, .accountInvite, .budgetInvite:
            pendingDeepLink = link
        }
    }

    func initialize() async {
        // Before anything can refresh a token: the SDK may end the session
        // on its own and only tells through this stream (Y1).
        authManager.startObservingAuthEvents()
        await authManager.checkSession()
        if authManager.isAuthenticated {
            await loadAfterAuth()
        }
    }

    /// Prepares the app for the signed-in user. Returns as soon as there is
    /// something to show: with a disk cache that is after the cache decode
    /// (tens of ms) — the network refresh continues in the background (P3).
    /// Without a cache it waits for the refresh. The splash stays up until
    /// this returns, so nothing here may wait on the network unbounded.
    func loadAfterAuth() async {
        // Cold start calls this from `initialize()` AND from the
        // `isAuthenticated` change in ContentView — the second caller waits
        // for the first instead of returning before the refresh exists.
        if let running = loadAfterAuthTask {
            await running.value
            return
        }
        guard !hasLoadedData else { return }
        let task = Task { @MainActor [weak self] () -> Void in
            await self?.performLoadAfterAuth()
        }
        loadAfterAuthTask = task
        await task.value
        // A sign-out during the wait may have started a new user's load.
        if loadAfterAuthTask == task { loadAfterAuthTask = nil }
    }

    @ObservationIgnored private var loadAfterAuthTask: Task<Void, Never>?

    private func performLoadAfterAuth() async {
        let epoch = dataStore.sessionEpoch
        hasLoadedData = true
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarding_completed")
        Task { await ProfileRepository().updateTimezoneIfNeeded() }  // server needs the user's local day (budgets, pushes)
        if let userId = authManager.currentUser?.id.uuidString.lowercased() {
            // Queued writes of a different (previous) user never replay
            // under this session.
            dataStore.offlineQueue.adoptOwner(userId)
        }

        await NetworkMonitor.shared.waitForFirstUpdate()
        guard epoch == dataStore.sessionEpoch else { return }

        // Cached FX rates first: without them USD balances render 1:1 as
        // the base currency until the network answers. Set before the cache
        // decode, whose `rebuildCaches()` reads them.
        if currencyManager.rates.isEmpty, let cached = Self.cachedRates() {
            currencyManager.rates = cached
        }
        let hasCache = await dataStore.loadCachedDataIfNeeded()
        guard epoch == dataStore.sessionEpoch else { return }

        let refresh = Task { @MainActor [weak self] () -> Void in
            await self?.refreshAfterAuth()
        }
        backgroundRefresh = refresh
        if !hasCache || currencyManager.rates.isEmpty {
            await refresh.value
        }
    }

    /// Waits for the refresh `loadAfterAuth()` started (no-op if none).
    func waitForInitialRefresh() async {
        await backgroundRefresh?.value
    }

    private func refreshAfterAuth() async {
        let epoch = dataStore.sessionEpoch
        let online = NetworkMonitor.shared.isConnected

        // Rates ALWAYS load — offline they come straight from the
        // UserDefaults cache (ExchangeRateService skips the network when
        // disconnected).
        let currencyManager = self.currencyManager
        async let data: () = dataStore.loadAll()
        async let rates: () = { _ = try? await withTimeout(seconds: 8) { await currencyManager.fetchRates() } }()
        if online {
            // Hard ceiling: Supabase SDK retries stack up on a flaky
            // connection.
            let paymentManager = self.paymentManager
            async let premium: () = { _ = try? await withTimeout(seconds: 8) { await paymentManager.checkPremiumStatus() } }()
            _ = await premium
        }
        _ = await (rates, data)
        guard epoch == dataStore.sessionEpoch else { return }

        // `fetchRates()` and `loadAll()` run concurrently — when rates
        // arrive after `loadAll()`'s internal `rebuildCaches()`, the
        // cached FX context inside `DataStore` is built with stale rates.
        // Re-run after both finish so balances and `amountInBase(_:)`
        // see the live FX table.
        dataStore.currencyContextDidChange()
        if online { await sessionEffects.registerPushToken() }
    }

    /// Last FX table `ExchangeRateService` cached (same UserDefaults slot),
    /// used for the instant start before the network refresh.
    private static func cachedRates() -> [String: Double]? {
        guard let data = UserDefaults.standard.data(forKey: "cached_exchange_rates"),
              let rates = try? JSONDecoder().decode([String: Double].self, from: data),
              !rates.isEmpty else { return nil }
        return rates
    }

    // MARK: - Sign-out (Y1)

    /// Explicit sign-out. Never fails: the network part is best effort, the
    /// local part always runs — offline sign-out used to leave the UI
    /// signed in with no session behind it.
    func signOut() async {
        await authManager.withExplicitSignOut {
            await sessionEffects.unregisterPushToken()
            // Y3: wipe BEFORE the session goes. Revoking can take seconds;
            // if the app died in between (or the SDK dropped the session),
            // the previous user's cache stayed on disk for the next one.
            resetForSignOut()
            await authManager.signOut()
        }
    }

    /// Deletes the account server-side, then signs out and wipes local
    /// state. Throws (and changes nothing locally) when the deletion failed.
    func deleteAccount() async throws {
        try await authManager.withExplicitSignOut {
            try await authManager.deleteAccount()
            hasCompletedOnboarding = false
            resetForSignOut()
            await authManager.signOut()
        }
    }

    /// One place that forgets the previous user: data store (memory, disk
    /// cache, offline queue unless `preserveQueue`), journal, premium flag,
    /// widget snapshot, local notifications, push token. Next sign-in loads
    /// from scratch.
    func resetForSignOut(preserveQueue: Bool = false) {
        hasLoadedData = false
        pendingDeepLink = nil
        QuickEntryInbox.shared.reset()
        // In-flight work of the previous user finishes on its own; the data
        // store discards its results (session epoch). The next sign-in
        // starts fresh instead of joining it.
        loadAfterAuthTask = nil
        backgroundRefresh?.cancel()
        backgroundRefresh = nil
        dataStore.resetForSignOut(preserveQueue: preserveQueue)
        BudgetMetricsStore.shared.reset()
        NotificationManager.recordServerPushRegistration(userId: nil)
        journalViewModel.reset()
        debts.reset()
        paymentManager.isPremium = false
        sessionEffects.clearDeviceState()
    }
}
