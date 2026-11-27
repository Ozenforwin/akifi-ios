import SwiftUI

struct HomeTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(CurrentAccountContext.self) private var currentAccountContext
    @State private var viewModel = HomeViewModel()
    @State private var showAddAccount = false
    @State private var showProfile = false
    @State private var showShareAccount = false
    @State private var showSearch = false
    @State private var editingAccount: Account?
    @State private var sharingAccount: Account?
    @State private var editingTransaction: Transaction?
    @State private var showBankImport = false
    @State private var showReceiptScanner = false
    @State private var showAddTransaction = false

    @Environment(\.scenePhase) private var scenePhase

    private var dataStore: DataStore { appViewModel.dataStore }
    /// Static, not an instance stored on the view: a class instance in a
    /// View's stored properties makes every value of the view "different",
    /// so each MainTabView pass re-ran this whole body (P4).
    private static let accountRepo = AccountRepository()

    private var isNewUser: Bool { dataStore.transactions.isEmpty }

    private var selectedAccount: Account? {
        viewModel.selectedAccount(from: dataStore.accounts)
    }

    /// Shared = the account has more than one member in `account_members`
    /// (B7). Until the membership snapshot is loaded (first launch offline)
    /// fall back to the old signal — someone else has rows on it — read from
    /// the memoized index instead of scanning every transaction per render.
    private func isSharedAccount(_ account: Account) -> Bool {
        let viewerId = dataStore.profile?.id
        if let shared = dataStore.accountMembership.isShared(account.id, viewerId: viewerId) {
            return shared
        }
        return dataStore.profilesMap.count > 1
            && dataStore.derivedCache.transactionIndex(for: dataStore).accountsWithOtherAuthors.contains(account.id)
    }

    /// Latest 10 rows (one per transfer group) for the carousel's account,
    /// memoized per data revision.
    private var recentTransactionsForAccount: [Transaction] {
        dataStore.derivedCache.recentTransactions(for: dataStore, accountId: selectedAccount?.id)
    }

    /// Changes when the signed-in user or the set of accounts changes —
    /// both can change who is a member of what.
    private var membershipTrigger: String {
        (dataStore.profile?.id ?? "") + "|" + dataStore.accounts.map(\.id).sorted().joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // 0. Header — the navigation bar (title + currency and
                    //    profile toolbar items, see `HomeTabToolbar`).

                    // 1. Account Carousel
                    accountSection

                    // 1b. Shared account detail shortcut (surfaces settlement card)
                    if !isNewUser, let acc = selectedAccount, isSharedAccount(acc) {
                        NavigationLink(destination: SharedAccountDetailView(account: acc)) {
                            SharedAccountShortcutCard(account: acc)
                        }
                        .buttonStyle(.plain)
                    }

                    // 1c. «Долги» — people, never part of the account totals.
                    if !isNewUser {
                        DebtsHomeEntry()
                    }

                    // 2. Streak
                    StreakBadgeView()

                    // 3. AI Insights
                    InsightCardsView()
                        .spotlight(.insightCards)

                    // 4. Savings
                    HomeSavingsSnapshotView()

                    // NOTE: Net Worth shortcut moved to Settings with a BETA
                    // badge — data quality is still rough (sums look
                    // duplicative when user has no assets/liabilities) and
                    // it doesn't deserve prime Home real estate yet.

                    // 4c. Deposits shortcut — aggregate principal+accrued
                    //     and nearest maturity countdown. Hidden until
                    //     the user has at least one deposit.
                    if !isNewUser && dataStore.accounts.contains(where: { $0.accountType == .deposit }) {
                        NavigationLink(destination: DepositListView()) {
                            DepositsShortcutCard()
                        }
                        .buttonStyle(.plain)
                    }

                    // 6. Summary Cards
                    summarySection

                    // NOTE: "Отчёты" (Reports, PDF export) and "Челленджи"
                    // (Savings Challenges) have been moved to Settings with a
                    // BETA badge — functionality is still rough around the
                    // edges and doesn't deserve premium Home real estate yet.

                    // 7. Recent Transactions
                    transactionsSection
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            // The system insets content for the tab bar; this is only the
            // room the floating «+» needs so the last row can scroll clear.
            .contentMargins(.bottom, AkifiChrome.floatingButtonClearance, for: .scrollContent)
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await dataStore.loadAll()
                await dataStore.accountMembership.refresh(viewerId: dataStore.profile?.id, force: true)
                // «Доступно сегодня» comes from the server's budget numbers;
                // an explicit pull asks for them again (Y2).
                await BudgetMetricsStore.shared.refresh(dataStore: dataStore, force: true)
            }
            .task(id: membershipTrigger) {
                await dataStore.accountMembership.refresh(viewerId: dataStore.profile?.id)
            }
            .onChange(of: scenePhase) { _, phase in
                // A partner accepting an invite changes membership without
                // touching our account list — re-check on return to the app.
                guard phase == .active else { return }
                Task { await dataStore.accountMembership.refresh(viewerId: dataStore.profile?.id) }
            }
            .animation(.easeOut(duration: 0.4), value: isNewUser)
            .navigationTitle(String(localized: "tab.home"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                HomeTabToolbar { showProfile = true }
            }
            .navigationDestination(isPresented: $showProfile) {
                SettingsView()
            }
            .sheet(isPresented: $showAddAccount) {
                AccountFormView {
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $sharingAccount) { account in
                ShareAccountView(account: account)
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
            }
            .sheet(item: $editingAccount) { account in
                AccountFormView(editingAccount: account) {
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                if transaction.isTransfer {
                    TransferFormView(
                        accounts: dataStore.accounts,
                        editingTransaction: transaction
                    ) {
                        await dataStore.loadAll()
                    }
                } else {
                    TransactionFormView(
                        categories: dataStore.displayCategories,
                        accounts: dataStore.accounts,
                        editingTransaction: transaction
                    ) {
                        await dataStore.loadAll()
                    }
                }
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.displayCategories,
                    accounts: dataStore.accounts
                ) {
                    // loadAll (not just rebuildCaches) — matches every other
                    // form completion: picks up server-side effects like
                    // auto-transfer triplets and subscription auto-match.
                    await dataStore.loadAll()
                }
            }
            .sheet(isPresented: $showBankImport) {
                NavigationStack {
                    BankImportView()
                }
            }
            .sheet(isPresented: $showReceiptScanner) {
                ReceiptScannerView {
                    await dataStore.loadAll()
                }
            }
            // Mirror the carousel's selected account into the shared
            // FAB context so the new-transaction sheet can pre-fill the
            // Account picker. Re-syncs when the carousel scrolls or when
            // the accounts list itself changes (e.g. after a fresh load).
            .onAppear {
                currentAccountContext.accountId = selectedAccount?.id
            }
            .onChange(of: viewModel.selectedAccountIndex) { _, _ in
                currentAccountContext.accountId = selectedAccount?.id
            }
            .onChange(of: dataStore.accounts.map(\.id)) { _, _ in
                currentAccountContext.accountId = selectedAccount?.id
            }
            // A widget opened this account (akifi://account?id=): select it
            // once the accounts are in — also on a cold start, when the
            // link came before the data.
            .onChange(of: pendingAccountTrigger, initial: true) { _, _ in
                applyPendingAccount()
            }
        }
    }

    // MARK: - Account from a widget

    private struct PendingAccountTrigger: Equatable {
        let id: String?
        let accountIds: [String]
        let isLoading: Bool
    }

    private var pendingAccountTrigger: PendingAccountTrigger {
        PendingAccountTrigger(
            id: appViewModel.pendingHomeAccountId,
            accountIds: dataStore.accounts.map(\.id),
            isLoading: dataStore.isLoading
        )
    }

    private func applyPendingAccount() {
        guard let id = appViewModel.pendingHomeAccountId else { return }
        if viewModel.applyPendingAccount(id, accounts: dataStore.accounts, isLoading: dataStore.isLoading) {
            appViewModel.pendingHomeAccountId = nil
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private var accountSection: some View {
        if isNewUser {
            AccountCarouselView(
                accounts: DemoData.accounts,
                selectedIndex: .constant(0),
                balanceFor: { _ in DemoData.accounts.first?.initialBalance ?? 0 },
                onAddAccount: { showAddAccount = true },
                onEditAccount: { _ in },
                onShareAccount: { _ in },
                onSetPrimary: { _ in }
            )
            .demoBlur(
                hint: String(localized: "welcome.accountHint"),
                buttonTitle: String(localized: "home.addAccount")
            ) { showAddAccount = true }
        } else if dataStore.accounts.isEmpty {
            // Empty state: the one place a full-width primary button belongs.
            Button {
                showAddAccount = true
            } label: {
                Label(String(localized: "home.addAccount"), systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.akifiPrimary)
            .controlSize(.large)
        } else {
            AccountCarouselView(
                accounts: dataStore.accounts,
                selectedIndex: $viewModel.selectedAccountIndex,
                balanceFor: dataStore.balance,
                onAddAccount: { showAddAccount = true },
                onEditAccount: { account in editingAccount = account },
                onShareAccount: { account in sharingAccount = account },
                onSetPrimary: { account in
                    guard !account.isPrimary else { return }
                    Task {
                        do {
                            try await Self.accountRepo.setPrimary(id: account.id)
                            await dataStore.loadAll()
                            viewModel.selectedAccountIndex = 0
                        } catch {
                            print("⭐ setPrimary error: \(error)")
                        }
                    }
                }
            )
            .spotlight(.accountCard)
        }
    }

    // MARK: - Summary Section

    @ViewBuilder
    private var summarySection: some View {
        if isNewUser {
            SummaryCardsView(
                transactions: DemoData.transactions,
                selectedAccount: nil
            )
            .demoBlur(
                hint: String(localized: "welcome.summaryHint"),
                buttonTitle: String(localized: "welcome.addTransaction")
            ) { showAddTransaction = true }
        } else {
            SummaryCardsView(
                transactions: dataStore.transactions,
                selectedAccount: viewModel.selectedAccount(from: dataStore.accounts)
            )
            .spotlight(.summaryCards)
        }
    }

    // MARK: - Transactions Section

    @ViewBuilder
    private var transactionsSection: some View {
        if isNewUser {
            RecentTransactionsView(
                transactions: DemoData.transactions,
                categories: DemoData.categories
            )
            .demoBlur(
                hint: String(localized: "welcome.transactionsHint"),
                buttonTitle: String(localized: "welcome.addTransaction")
            ) { showAddTransaction = true }
        } else {
            RecentTransactionsView(
                transactions: recentTransactionsForAccount,
                categories: dataStore.categories,
                onEdit: { tx in editingTransaction = tx },
                onDelete: { tx in
                    Task { await dataStore.deleteTransaction(tx) }
                }
            )
        }
    }
}

// MARK: - Shared Account Shortcut Card

/// Row-like card under the carousel that opens the shared account's detail
/// (settlement). Content, not glass; the account colour tints the icon
/// tile only.
private struct SharedAccountShortcutCard: View {
    let account: Account

    @ScaledMetric(relativeTo: .body) private var iconTileSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: account.color))
                .frame(width: iconTileSize, height: iconTileSize)
                .background(Color(hex: account.color).opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "sharedAccount.openDetail"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(localized: "settlement.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .akifiCard()
        .contentShape(RoundedRectangle(cornerRadius: CardStyle.Size.regular.cornerRadius, style: .continuous))
    }
}
