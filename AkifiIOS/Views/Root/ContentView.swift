import SwiftUI

// MARK: - App Tab

enum AppTab: Int, CaseIterable {
    case home = 0
    case transactions = 1
    case analytics = 2
    case journal = 3
    case budgets = 4

    var screenName: String {
        switch self {
        case .home: "Home"
        case .transactions: "Transactions"
        case .analytics: "Analytics"
        case .journal: "Journal"
        case .budgets: "Budgets"
        }
    }
}

enum SheetDestination: Identifiable {
    case expense(categoryId: String? = nil, accountId: String? = nil)
    case income(categoryId: String? = nil, accountId: String? = nil)
    case transfer
    case receipt

    var id: String {
        switch self {
        case .expense: "expense"
        case .income: "income"
        case .transfer: "transfer"
        case .receipt: "receipt"
        }
    }
}

struct ContentView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showSplash = true

    var body: some View {
        @Bindable var auth = appViewModel.authManager
        ZStack {
            Group {
                if !showSplash && !appViewModel.authManager.isLoading {
                    if appViewModel.authManager.isPasswordRecoveryPending {
                        // A password-reset link signed the user in (A1).
                        NewPasswordView()
                    } else if !appViewModel.authManager.isAuthenticated {
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
        // One handler for every URL, also on the login screen: email links
        // (A1) must work signed out, invites wait for the signed-in UI.
        .onOpenURL { url in
            appViewModel.open(url)
        }
        // An email link that failed with no auth sheet on screen (cold
        // start from the link, or already signed in).
        .errorToast($auth.authLinkError)
        .task {
            // `initialize()` returns as soon as the disk cache is on screen
            // (P3) — the network refresh continues behind the UI. Without a
            // cache (first launch) it waits for the network.
            let initTask = Task { await appViewModel.initialize() }
            try? await Task.sleep(for: .seconds(1.5))
            // The splash must never be held hostage by the network: if
            // init is still running after 12 s (offline cold start with an
            // expired token stacks SDK retries), show the UI — cached data
            // renders and init finishes in the background.
            _ = try? await withTimeout(seconds: 12) { await initTask.value }
            if appViewModel.authManager.isLoading {
                // Init blew the deadline before auth resolved — decide from
                // the keychain and load cached data so the screen behind
                // the splash is never empty (black screen).
                appViewModel.authManager.forceResolveFromLocalSession()
                if appViewModel.authManager.isAuthenticated {
                    await appViewModel.loadAfterAuth()
                }
            }
            withAnimation(.easeOut(duration: 0.4)) {
                showSplash = false
            }
            // Once the background refresh has fresh subscriptions, reconcile
            // pending notifications with them. Non-blocking for the UI.
            Task {
                await appViewModel.waitForInitialRefresh()
                guard appViewModel.authManager.isAuthenticated else { return }
                let subs = appViewModel.dataStore.subscriptions
                await NotificationManager.rescheduleAllReminders(subscriptions: subs)
                await scheduleWeeklyDigestIfNeeded()
            }
        }
        .onChange(of: appViewModel.authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task {
                    await appViewModel.loadAfterAuth()
                    await appViewModel.waitForInitialRefresh()
                    guard appViewModel.authManager.isAuthenticated else { return }
                    let subs = appViewModel.dataStore.subscriptions
                    await NotificationManager.rescheduleAllReminders(subscriptions: subs)
                    await scheduleWeeklyDigestIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func scheduleWeeklyDigestIfNeeded() async {
        let dataStore = appViewModel.dataStore
        let fmt = appViewModel.currencyManager
        // Snapshot on main actor before crossing concurrency boundary.
        let transactions = dataStore.transactions
        let categories = dataStore.categories
        let budgets = dataStore.budgets
        let subscriptions = dataStore.subscriptions
        let ctx = dataStore.currencyContext
        let body = InsightEngine.weeklyDigest(
            InsightEngine.Input(
                transactions: transactions,
                categories: categories,
                budgets: budgets,
                subscriptions: subscriptions,
                formatAmount: { amount in
                    MainActor.assumeIsolated { fmt.formatAmount(amount.displayAmount) }
                },
                formatAmountInCurrency: { amount, currency in
                    InsightCardsView.formatInCurrency(amount: amount, currency: currency)
                },
                accountsById: ctx.accountsById,
                fxRates: ctx.fxRates,
                baseCode: ctx.baseCode,
                externalSpendByBudget: dataStore.externalSpendByBudget
            )
        )
        // Not when notifications are off, not when the server sends it (N2).
        await NotificationManager.syncWeeklyDigest(
            body: body,
            userId: appViewModel.authManager.currentUser?.id.uuidString.lowercased()
        )
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var selectedTab: AppTab = .home
    @State private var showAssistant = false
    @State private var assistantVM = AssistantViewModel()
    @State private var activeSheet: SheetDestination?
    @State private var fabSelectedCategoryId: String?
    @State private var unlockedAchievement: Achievement?
    @State private var pendingStreakMilestone: StreakTracker.MilestoneInfo?
    @State private var spotlightManager = SpotlightManager()
    @State private var pendingInvite: PendingInvite?

    private struct PendingInvite: Identifiable {
        let code: String
        let kind: AcceptInviteView.InviteKind
        var id: String { "\(kind)-\(code)" }
    }
    /// Tracks the account the user is currently "looking at" (Home carousel
    /// selection or a pushed shared-account detail). Read by the FAB to
    /// preselect the Account picker on the new-transaction sheet. Only
    /// honored while `selectedTab == .home` — the other tabs don't have
    /// a contextual account.
    @State private var currentAccountContext = CurrentAccountContext()
    /// Debounced offline-queue sync fired when connectivity returns.
    @State private var reconnectSyncTask: Task<Void, Never>?
    /// Tabs the user has visited at least once. Visited tabs stay alive
    /// (hidden, not destroyed) so their panel caches, scroll positions and
    /// navigation stacks survive switches — recreating Analytics from
    /// scratch on every switch was a visible 1-2 s freeze.
    @State private var visitedTabs: Set<AppTab> = [.home]

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content area — lazily-populated keep-alive stack. A tab is
            // built on first visit and then merely hidden; @Observable
            // invalidations keep hidden tabs' caches warm in the background
            // (cheap: every panel is memoized), so returning is instant.
            ZStack {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    if visitedTabs.contains(tab) {
                        tabContent(for: tab)
                            .opacity(selectedTab == tab ? 1 : 0)
                            .allowsHitTesting(selectedTab == tab)
                            .accessibilityHidden(selectedTab != tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom opaque tab bar (replaces system TabView to avoid iOS 26 liquid glass)
            CustomTabBar(selectedTab: $selectedTab, onAITap: openAssistant)

            // FAB
            FABView { action in
                // Only forward the contextual account on tabs where it makes
                // sense (Home carousel + pushed shared-account screens). On
                // Analytics / Budgets / etc. there's no "current account",
                // so we leave the form's Account picker empty.
                let contextualAccountId: String? = selectedTab == .home
                    ? currentAccountContext.accountId
                    : nil
                switch action {
                case .income(let categoryId):
                    fabSelectedCategoryId = categoryId
                    activeSheet = .income(categoryId: categoryId, accountId: contextualAccountId)
                case .expense(let categoryId):
                    fabSelectedCategoryId = categoryId
                    activeSheet = .expense(categoryId: categoryId, accountId: contextualAccountId)
                case .transfer:
                    activeSheet = .transfer
                case .receipt:
                    activeSheet = .receipt
                }
            }

            // Achievement overlay
            if let achievement = unlockedAchievement {
                LevelUpView(
                    achievementName: achievement.localizedName,
                    points: achievement.points,
                    icon: achievement.icon,
                    tier: achievement.tier.rawValue
                ) {
                    unlockedAchievement = nil
                }
                .transition(.opacity)
            }

            // Streak milestone overlay
            if let milestone = pendingStreakMilestone {
                StreakMilestoneView(info: milestone) {
                    pendingStreakMilestone = nil
                }
                .transition(.opacity)
                .zIndex(4)
            }

            // Offline indicator
            if !NetworkMonitor.shared.isConnected {
                let pendingCount = appViewModel.dataStore.offlineQueue.pendingCount
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                        Text(
                            pendingCount > 0
                                ? String(format: String(localized: "status.offline.pending"), pendingCount)
                                : String(localized: "status.offline")
                        )
                        .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.orange))
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: NetworkMonitor.shared.isConnected)
                .zIndex(3)
            }

            // Top banners (non-modal, below overlays): data problems (Y7) and
            // the subscription auto-match undo. Stacked, never overlapping.
            let dataIssue = appViewModel.dataStore.issue
            let match = appViewModel.dataStore.pendingAutoMatch
            if dataIssue != nil || match != nil {
                VStack(spacing: 8) {
                    if let dataIssue {
                        DataIssueBanner(
                            issue: dataIssue,
                            onRetry: {
                                let dataStore = appViewModel.dataStore
                                switch dataIssue.kind {
                                case .load: return { Task { await dataStore.loadAll() } }
                                case .unsynced: return { Task { await dataStore.retryUnsyncedOperations() } }
                                case .mutation: return nil
                                }
                            }(),
                            onDismiss: { appViewModel.dataStore.dismissIssue() }
                        )
                        .id(dataIssue.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let match {
                        SubscriptionMatchBanner(
                            match: match,
                            onUndo: {
                                Task { await appViewModel.dataStore.undoAutoMatch() }
                            },
                            onDismiss: {
                                appViewModel.dataStore.clearPendingAutoMatch(id: match.id)
                            }
                        )
                        .id(match.id)
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .zIndex(2)
                .animation(.easeInOut(duration: 0.25), value: match)
                .animation(.easeInOut(duration: 0.25), value: dataIssue)
            }

            // Spotlight onboarding overlay (must be LAST — above everything)
            SpotlightOverlayView(manager: spotlightManager)
        }
        .environment(currentAccountContext)
        .onPreferenceChange(SpotlightFramePreferenceKey.self) { newFrames in
            Task { @MainActor in spotlightManager.frames = newFrames }
        }
        .onChange(of: spotlightManager.currentStepIndex) { _, _ in
            if let tab = spotlightManager.requiredTab, tab != selectedTab {
                withAnimation(.easeInOut(duration: 0.3)) { selectedTab = tab }
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            visitedTabs.insert(newTab)
            AnalyticsService.logScreen(newTab.screenName)
        }
        .onChange(of: NetworkMonitor.shared.isConnected) { wasConnected, isConnected in
            // Drain the offline queue as soon as connectivity returns.
            // Short debounce so a flapping path (elevator Wi-Fi) doesn't
            // fire overlapping sync rounds; the queue's isProcessing guard
            // is the second line of defense.
            reconnectSyncTask?.cancel()
            guard !wasConnected, isConnected else { return }
            reconnectSyncTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await appViewModel.dataStore.syncPendingOperations()
                // Rates may be stale (or fallback) after an offline start —
                // refresh them now that the network is back so FX-converted
                // balances snap to real values.
                await appViewModel.currencyManager.fetchRates()
                appViewModel.dataStore.currencyContextDidChange()
            }
        }
        .task {
            // Defer spotlight for new users — show it after first transaction
            if !appViewModel.dataStore.transactions.isEmpty {
                try? await Task.sleep(for: .seconds(1.0))
                spotlightManager.start()
            }
        }
        .background {
            // Observes `transactions` in its own tiny view: an `onChange` here
            // made every data change re-run this whole body and rebuild the
            // struct of every kept-alive tab (P2).
            TransactionCountObserver { newCount in
                if newCount > 0 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.0))
                        spotlightManager.start()
                    }
                    // Streak milestone check (piggy-backs on transaction change).
                    checkStreakMilestone()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushNotificationTapped)) { notification in
            if let tabName = notification.userInfo?["tab"] as? String {
                withAnimation {
                    switch tabName {
                    case "home": selectedTab = .home
                    case "transactions": selectedTab = .transactions
                    case "budget", "budgets": selectedTab = .budgets
                    case "analytics": selectedTab = .analytics
                    default: break
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .fullScreenCover(isPresented: $showAssistant) {
            AssistantView(viewModel: assistantVM) { target in
                handleNavigationTarget(target)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .expense(let categoryId, let accountId):
                    TransactionFormView(
                        categories: appViewModel.dataStore.displayCategories,
                        accounts: appViewModel.dataStore.accounts,
                        defaultCategoryId: categoryId,
                        defaultAccountId: accountId
                    ) {
                        await appViewModel.dataStore.loadAll()
                        fabSelectedCategoryId = nil
                    }
                case .income(let categoryId, let accountId):
                    TransactionFormView(
                        categories: appViewModel.dataStore.displayCategories,
                        accounts: appViewModel.dataStore.accounts,
                        defaultType: .income,
                        defaultCategoryId: categoryId,
                        defaultAccountId: accountId
                    ) {
                        await appViewModel.dataStore.loadAll()
                        fabSelectedCategoryId = nil
                    }
                case .transfer:
                    TransferFormView(accounts: appViewModel.dataStore.accounts) {
                        await appViewModel.dataStore.loadAll()
                    }
                case .receipt:
                    ReceiptScannerView {
                        await appViewModel.dataStore.loadAll()
                    }
                }
            }
        }
        .task { await checkNewAchievements() }
        // URLs arrive in ContentView (`AppViewModel.open`); widget taps and
        // invites wait in `pendingDeepLink` — also when they came in on the
        // login screen (`initial: true` consumes them on first appearance).
        .onChange(of: appViewModel.pendingDeepLink, initial: true) { _, link in
            guard let link else { return }
            appViewModel.pendingDeepLink = nil
            switch link {
            case .tab(let tab):
                withAnimation { selectedTab = tab }
                AnalyticsService.logEvent("widget_tap", params: ["target": tab.screenName.lowercased()])
            case .accountInvite(let code):
                pendingInvite = PendingInvite(code: code, kind: .account)
            case .budgetInvite(let code):
                pendingInvite = PendingInvite(code: code, kind: .budget)
            case .authCallback:
                break  // handled by AuthManager
            }
        }
        // S2: the link opens a confirmation screen — who invites, to what,
        // with which role and what they will see. Joining needs a tap.
        .sheet(item: $pendingInvite) { invite in
            AcceptInviteView(initialCode: invite.code, kind: invite.kind)
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeTabView()
        case .transactions: TransactionsTabView()
        case .analytics: AnalyticsTabView()
        case .journal: JournalTabView()
        case .budgets: BudgetsTabView()
        }
    }

    /// The assistant's request carries the client context (balances in
    /// account currency, FX rates, display currency, language) built from
    /// the data store — which was never attached, so every request went
    /// out without it.
    private func openAssistant() {
        assistantVM.dataStore = appViewModel.dataStore
        showAssistant = true
    }

    private func handleNavigationTarget(_ target: NavigationTarget) {
        switch target {
        case .transactions:
            selectedTab = .transactions
        case .budgets:
            selectedTab = .budgets
        case .savings:
            selectedTab = .budgets
        case .journal:
            break
        case .addExpense:
            activeSheet = .expense(categoryId: nil)
        case .addIncome:
            activeSheet = .income(categoryId: nil)
        }
    }

    private func checkStreakMilestone() {
        let streak = StreakTracker.currentStreak(from: appViewModel.dataStore.transactions)
        guard streak > 0 else { return }
        if let milestone = StreakTracker.detectNewMilestone(currentStreak: streak) {
            withAnimation {
                pendingStreakMilestone = StreakTracker.info(for: milestone)
            }
            AnalyticsService.logEvent(
                "streak_milestone_reached",
                params: ["days": milestone]
            )
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

// MARK: - Data issue banner (Y7)

/// Small top banner for `DataStore.issue`: a refresh that only partly
/// succeeded (cached values are showing) or a user action that failed.
/// Auto-dismisses; a load problem offers "Повторить".
private struct DataIssueBanner: View {
    let issue: DataStore.Issue
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.kind == .load ? "exclamationmark.arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(issue.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRetry {
                Button(String(localized: "sync.error.retry")) {
                    onRetry()
                    onDismiss()
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .task(id: issue.id) {
            // Refused writes stay until the user acts on them (Y6).
            guard issue.kind != .unsynced else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}

/// Zero-size observer of the transaction count, so `MainTabView.body`
/// itself doesn't depend on `transactions`.
private struct TransactionCountObserver: View {
    @Environment(AppViewModel.self) private var appViewModel
    let onChange: (Int) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: appViewModel.dataStore.transactions.count) { _, newCount in
                onChange(newCount)
            }
    }
}

// MARK: - Custom Tab Bar (opaque, no liquid glass)

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab
    @AppStorage("hapticEnabled") private var hapticEnabled = true
    var onAITap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton("house.fill", String(localized: "tab.home"), .home)
                tabButton("arrow.left.arrow.right", String(localized: "tab.transactions"), .transactions)

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
                            .frame(width: 48, height: 48)
                            .shadow(color: Color.aiGradientStart.opacity(0.2), radius: 8, x: 0, y: 4)

                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .offset(y: -20)
                    .spotlight(.aiButton)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(String(localized: "tab.assistant"))

                tabButton("chart.bar.fill", String(localized: "tab.analytics"), .analytics)
                tabButton("wallet.bifold.fill", String(localized: "tab.budgets"), .budgets)
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

    private func tabButton(_ icon: String, _ label: String, _ tab: AppTab) -> some View {
        Button {
            if hapticEnabled { HapticManager.light() }
            // Screen logging lives in MainTabView's onChange(selectedTab):
            // one point covers taps AND programmatic switches (deep links,
            // spotlight, push taps), and re-tapping the active tab no
            // longer emits duplicate screen events.
            selectedTab = tab
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selectedTab == tab ? Color.accent : Color(.secondaryLabel))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}
