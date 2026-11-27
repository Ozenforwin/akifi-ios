import SwiftUI

enum SheetDestination: Identifiable {
    /// The full form, prefilled — quick entry's «Подробнее».
    case transactionForm(TransactionFormPrefill)
    case transfer
    case receipt

    var id: String {
        switch self {
        case .transactionForm: "transactionForm"
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

/// The signed-in shell (1.6): system `TabView` (Liquid Glass on iOS 26) with
/// Главная · Операции · Аналитика · Бюджеты and the Assistant as the
/// separate trailing round tab, the floating «+», top banners and the
/// app-wide overlays (achievements, streaks, spotlight tour).
///
/// Tab lifetime: the system `TabView` builds a tab on its first selection
/// and keeps it — state, scroll position and navigation stack survive
/// switches (what the pre-1.6 opacity keep-alive stack did by hand).
struct MainTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @AppStorage("hapticEnabled") private var hapticEnabled = true
    @State private var selectedTab: AppTab = .home
    @State private var assistantVM = AssistantViewModel()
    @State private var activeSheet: SheetDestination?
    /// The quick-entry sheet, its undo toast and the «Подробнее» hand-over.
    @State private var quickEntry = QuickEntryCoordinator()
    @State private var unlockedAchievement: Achievement?
    @State private var pendingStreakMilestone: StreakTracker.MilestoneInfo?
    @State private var spotlightManager = SpotlightManager()
    @State private var pendingInvite: PendingInvite?
    /// Top edge of the tab bar in global coordinates, per tab — the «+»
    /// floats just above it. Per tab because a hidden tab may re-lay out
    /// without the bar's inset and report the screen bottom; only the
    /// selected tab's value is used.
    @State private var tabBarTops: [AppTab: CGFloat] = [:]
    @State private var isKeyboardVisible = false
    /// The tour was due while the Assistant tab was open — it starts when
    /// the user leaves the chat instead of pulling them out of it.
    @State private var spotlightStartPending = false

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

    /// Gap between the top of the tab bar and the bottom of the «+».
    private static let addButtonGap: CGFloat = 12

    /// The `TabView`'s selection. Its setter runs for taps on the tab bar
    /// only — programmatic switches (deep links, push taps, spotlight, the
    /// assistant) assign `selectedTab` directly — so the tap haptic doesn't
    /// fire for them. Screen logging lives in `onChange(of: selectedTab)`:
    /// one point covers taps AND programmatic switches, and re-tapping the
    /// active tab emits no duplicate screen event.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab != selectedTab, hapticEnabled {
                    if newTab == .assistant { HapticManager.medium() } else { HapticManager.light() }
                }
                selectedTab = newTab
            }
        )
    }

    var body: some View {
        ZStack {
            tabView

            // «+» — above the tab bar, trailing. Hidden on the Assistant tab
            // and while a keyboard is up.
            GeometryReader { root in
                FABView(
                    bottomInset: addButtonBottomInset(rootFrame: root.frame(in: .global)),
                    trailingInset: AkifiChrome.floatingButtonTrailingInset,
                    isButtonVisible: AppTab.showsAddButton(on: selectedTab, keyboardVisible: isKeyboardVisible)
                ) { action in
                    handleFABAction(action)
                }
            }
            .ignoresSafeArea(edges: .bottom)

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

            // Top banners (non-modal, below overlays): offline state, data
            // problems (Y7) and the subscription auto-match undo. Small glass
            // capsules, stacked, never overlapping.
            topBanners
                .zIndex(2)

            // Spotlight onboarding overlay (must be LAST — above everything)
            SpotlightOverlayView(manager: spotlightManager)
                .zIndex(5)
        }
        .environment(currentAccountContext)
        .environment(spotlightManager)
        // Each step shows on its own tab (also the first one: the tour may
        // start while another tab is open).
        .onChange(of: spotlightStepKey) { _, _ in
            if let tab = spotlightManager.requiredTab, tab != selectedTab {
                withAnimation(.easeInOut(duration: 0.3)) { selectedTab = tab }
            }
        }
        // No step may point at nothing: once the step's tab had time to
        // appear, a step whose target isn't on screen is skipped.
        .task(id: spotlightStepKey) {
            guard spotlightManager.isActive else { return }
            try? await Task.sleep(for: SpotlightManager.anchorGracePeriod)
            guard !Task.isCancelled else { return }
            spotlightManager.skipStepIfUnanchored()
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            let shown = newTab.resolvedForTabBar
            if shown != newTab {
                selectedTab = shown
                return
            }
            if newTab == .assistant {
                assistantVM.dataStore = appViewModel.dataStore
            }
            AnalyticsService.logScreen(newTab.screenName)
            if oldTab == .assistant, spotlightStartPending {
                spotlightStartPending = false
                startSpotlight(after: .seconds(0.5))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
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
            // The assistant's request carries the client context (balances
            // in account currency, FX rates, display currency, language)
            // built from the data store — attach it before the Assistant tab
            // can be opened.
            assistantVM.dataStore = appViewModel.dataStore
            // Defer spotlight for new users — show it after first transaction
            if !appViewModel.dataStore.transactions.isEmpty {
                startSpotlight(after: .seconds(1.0))
            }
        }
        .background {
            // Observes `transactions` in its own tiny view: an `onChange` here
            // made every data change re-run this whole body and rebuild the
            // struct of every kept-alive tab (P2).
            TransactionCountObserver { newCount in
                if newCount > 0 {
                    startSpotlight(after: .seconds(1.0))
                    // Streak milestone check (piggy-backs on transaction change).
                    checkStreakMilestone()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushNotificationTapped)) { notification in
            if let tabName = notification.userInfo?["tab"] as? String,
               let tab = AppTab(pushTarget: tabName) {
                withAnimation { selectedTab = tab }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .transactionForm(let prefill):
                    TransactionFormView(
                        categories: appViewModel.dataStore.displayCategories,
                        accounts: appViewModel.dataStore.accounts,
                        prefill: prefill
                    ) {
                        await appViewModel.dataStore.loadAll()
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
        // Quick entry: «+», the inbox (links, quick actions, Control Center,
        // Siri), the assistant. «Подробнее» opens the form once the sheet
        // is gone (two sheets can't be up at once).
        .sheet(item: $quickEntry.presented, onDismiss: {
            if let prefill = quickEntry.takePendingDetails() {
                activeSheet = .transactionForm(prefill)
            } else {
                presentInboxRequestIfAny()
            }
        }) { presentation in
            QuickEntrySheet(
                model: presentation.model,
                onClose: { quickEntry.presented = nil },
                onSaved: { quickEntry.didSave($0) },
                onDetails: { quickEntry.openDetails() }
            )
        }
        .onChange(of: QuickEntryInbox.shared.pending?.id, initial: true) { _, _ in
            presentInboxRequestIfAny()
        }
        // A request that waited for another sheet goes when it closes.
        .onChange(of: activeSheet == nil && pendingInvite == nil) { _, free in
            if free { presentInboxRequestIfAny() }
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

    // MARK: - Tabs

    private var tabView: some View {
        TabView(selection: tabSelection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.systemImage, value: AppTab.home) {
                HomeTabView()
                    .background(TabBarTopReader { reportTabBarTop($0, from: .home) })
            }
            Tab(AppTab.transactions.title, systemImage: AppTab.transactions.systemImage, value: AppTab.transactions) {
                TransactionsTabView()
                    .background(TabBarTopReader { reportTabBarTop($0, from: .transactions) })
            }
            Tab(AppTab.analytics.title, systemImage: AppTab.analytics.systemImage, value: AppTab.analytics) {
                AnalyticsTabView()
                    .background(TabBarTopReader { reportTabBarTop($0, from: .analytics) })
            }
            Tab(AppTab.budgets.title, systemImage: AppTab.budgets.systemImage, value: AppTab.budgets) {
                BudgetsTabView()
                    .background(TabBarTopReader { reportTabBarTop($0, from: .budgets) })
            }
            Tab(AppTab.assistant.title, systemImage: AppTab.assistant.systemImage, value: AppTab.assistant, role: .search) {
                AssistantView(viewModel: assistantVM, showsCloseButton: false) { target in
                    handleNavigationTarget(target)
                }
            }
        }
        .akifiTabBarMinimizeOnScroll()
        .tint(Color.accent)
    }

    private func reportTabBarTop(_ top: CGFloat, from tab: AppTab) {
        if tabBarTops[tab] != top { tabBarTops[tab] = top }
    }

    /// Bottom inset of the «+» from the screen's bottom edge.
    private func addButtonBottomInset(rootFrame: CGRect) -> CGFloat {
        AkifiChrome.floatingButtonBottomInset(
            tabBarTop: tabBarTops[selectedTab],
            screenMaxY: rootFrame.maxY,
            gap: Self.addButtonGap
        )
    }

    // MARK: - Top banners

    @ViewBuilder
    private var topBanners: some View {
        let isOffline = !NetworkMonitor.shared.isConnected
        let dataIssue = appViewModel.dataStore.issue
        let match = appViewModel.dataStore.pendingAutoMatch
        let saved = quickEntry.toast
        if isOffline || dataIssue != nil || match != nil || saved != nil {
            VStack(spacing: 8) {
                if let saved {
                    QuickEntrySavedToast(
                        saved: saved,
                        onUndo: {
                            let dataStore = appViewModel.dataStore
                            Task { await quickEntry.undo(saved, dataStore: dataStore) }
                        },
                        onDismiss: { quickEntry.dismissToast(id: saved.id) }
                    )
                    .id(saved.id)
                }
                if isOffline {
                    OfflineBanner(pendingCount: appViewModel.dataStore.offlineQueue.pendingCount)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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
            // Below the navigation bar's control row: a banner must never
            // cover the toolbar buttons (profile, currency, filters).
            .padding(.top, AkifiChrome.bannerTopInset)
            .animation(.easeInOut(duration: 0.25), value: match)
            .animation(.easeInOut(duration: 0.25), value: saved)
            .animation(.easeInOut(duration: 0.25), value: dataIssue)
            .animation(.easeInOut, value: isOffline)
        }
    }

    // MARK: - Actions

    private var spotlightStepKey: SpotlightStepKey {
        SpotlightStepKey(isActive: spotlightManager.isActive, index: spotlightManager.currentStepIndex)
    }

    /// Starts the onboarding tour after `delay` (no-op once completed). Not
    /// over the Assistant tab: a first transaction added from the chat
    /// would otherwise yank the user to Home mid-conversation.
    private func startSpotlight(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard selectedTab != .assistant else {
                spotlightStartPending = true
                return
            }
            spotlightManager.start()
        }
    }

    private func handleFABAction(_ action: FABAction) {
        // The contextual account (Home carousel, pushed account screen)
        // only counts where it is a real choice — see
        // `QuickEntryCoordinator.pinnedAccountId`.
        let route = QuickEntryCoordinator.route(
            action,
            selectedTab: selectedTab,
            contextAccountId: currentAccountContext.accountId,
            accounts: appViewModel.dataStore.accounts
        )
        switch route {
        case .quickEntry(let mode, let categoryId, let accountId):
            presentQuickEntry(QuickEntryRequest(mode: mode, source: .addButton, categoryId: categoryId, accountId: accountId))
        case .transfer:
            activeSheet = .transfer
        case .receipt:
            activeSheet = .receipt
        case .debt(let debtAction):
            openDebtAction(debtAction)
        }
    }

    // INTEGRATION POINT — debts stream (1.6.0): open «Дал в долг» /
    // «Взял в долг» here, then set `FABMenu.showsDebtActions = true`.
    // Unreachable until then (the menu doesn't show the items).
    private func openDebtAction(_ action: FABDebtAction) {
        AppLogger.data.info("Debt action requested before the debts UI exists: \(String(describing: action), privacy: .public)")
    }

    private func presentQuickEntry(_ request: QuickEntryRequest) {
        quickEntry.present(request, dataStore: appViewModel.dataStore, currencyManager: appViewModel.currencyManager)
    }

    /// Takes the waiting `QuickEntryInbox` request (Siri, a link, a Home
    /// screen quick action, Control Center) unless another sheet is up.
    private func presentInboxRequestIfAny() {
        let otherSheet = activeSheet != nil || pendingInvite != nil
        guard let request = quickEntry.takeInboxRequest(from: QuickEntryInbox.shared, otherSheetPresented: otherSheet) else { return }
        presentQuickEntry(request)
    }

    private func handleNavigationTarget(_ target: NavigationTarget) {
        switch AssistantRoute(target) {
        case .selectTab(let tab):
            selectedTab = tab
        case .addExpense:
            presentQuickEntry(QuickEntryRequest(mode: .expense, source: .assistant))
        case .addIncome:
            presentQuickEntry(QuickEntryRequest(mode: .income, source: .assistant))
        case .none:
            break
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

/// `task(id:)` key of the spotlight anchor check.
private struct SpotlightStepKey: Equatable {
    let isActive: Bool
    let index: Int
}

/// Reports where the tab bar begins, in global coordinates: a reader laid
/// out in a tab's safe area ends exactly at the top of the tab bar (bar and
/// home indicator are the bottom inset). Measured on iOS 26.5: frame
/// maxY 791 on an 874 pt screen with an 83 pt tab bar region.
///
/// Use `frame.maxY` alone — the proxy's `safeAreaInsets` still report the
/// bar although the frame already excludes it. The keyboard is ignored: the
/// «+» hides while it is up and must come back to the same place.
private struct TabBarTopReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let top = geo.frame(in: .global).maxY
            Color.clear
                .onAppear { onChange(top) }
                .onChange(of: top) { _, newTop in onChange(newTop) }
        }
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Offline banner

/// Glass capsule shown while the device is offline, with the number of
/// writes waiting to sync.
struct OfflineBanner: View {
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.warning)
                .accessibilityHidden(true)
            Text(
                pendingCount > 0
                    ? String(format: String(localized: "status.offline.pending"), pendingCount)
                    : String(localized: "status.offline")
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
        }
        .akifiGlassBanner()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Data issue banner (Y7)

/// Small top banner for `DataStore.issue`: a refresh that only partly
/// succeeded (cached values are showing) or a user action that failed.
/// Auto-dismisses; a load problem offers "Повторить".
struct DataIssueBanner: View {
    let issue: DataStore.Issue
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.kind == .load ? "exclamationmark.arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.warning)
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close"))
        }
        // The 44 pt close button sets the height and the trailing spacing.
        .akifiGlassBanner(contentInsets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 4))
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
