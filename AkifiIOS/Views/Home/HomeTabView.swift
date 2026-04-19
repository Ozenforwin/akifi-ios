import SwiftUI

struct HomeTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
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

    private var dataStore: DataStore { appViewModel.dataStore }
    private let accountRepo = AccountRepository()

    private var isNewUser: Bool { dataStore.transactions.isEmpty }

    private var selectedAccount: Account? {
        viewModel.selectedAccount(from: dataStore.accounts)
    }

    /// True if the given account has transactions from more than one user
    /// — same heuristic used inside `AccountCarouselView` to render the
    /// "shared" badge.
    private func isSharedAccount(_ account: Account) -> Bool {
        let uid = dataStore.profile?.id
        return dataStore.profilesMap.count > 1
            && dataStore.transactions.contains { $0.accountId == account.id && $0.userId != uid }
    }

    private var recentTransactionsForAccount: [Transaction] {
        let txs: [Transaction]
        if let account = selectedAccount {
            txs = dataStore.transactions.filter { $0.accountId == account.id }
        } else {
            txs = dataStore.transactions
        }
        // Deduplicate transfers: show only one per transfer_group_id
        var seenGroups: Set<String> = []
        return Array(txs.filter { tx in
            if let groupId = tx.transferGroupId {
                if seenGroups.contains(groupId) { return false }
                seenGroups.insert(groupId)
            }
            return true
        }.prefix(10))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // 0. Header
                    AppHeaderView(showProfile: $showProfile)

                    // 1. Account Carousel
                    accountSection

                    // 1b. Shared account detail shortcut (surfaces settlement card)
                    if !isNewUser, let acc = selectedAccount, isSharedAccount(acc) {
                        NavigationLink(destination: SharedAccountDetailView(account: acc)) {
                            SharedAccountShortcutCard(account: acc)
                        }
                        .buttonStyle(.plain)
                    }

                    // 2. Streak
                    StreakBadgeView()

                    // 3. AI Insights
                    InsightCardsView()
                        .spotlight(.insightCards)

                    // 4. Savings
                    HomeSavingsSnapshotView()

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
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .refreshable {
                await dataStore.loadAll()
            }
            .animation(.easeOut(duration: 0.4), value: isNewUser)
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showProfile) {
                SettingsView()
            }
            .sheet(isPresented: $showAddAccount) {
                AccountFormView {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $sharingAccount) { account in
                ShareAccountView(account: account)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $editingAccount) { account in
                AccountFormView(editingAccount: account) {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $editingTransaction) { transaction in
                if transaction.isTransfer {
                    TransferFormView(
                        accounts: dataStore.accounts,
                        editingTransaction: transaction
                    ) {
                        await dataStore.loadAll()
                    }
                    .presentationBackground(.ultraThinMaterial)
                } else {
                    TransactionFormView(
                        categories: dataStore.displayCategories,
                        accounts: dataStore.accounts,
                        editingTransaction: transaction
                    ) {
                        await dataStore.loadAll()
                    }
                    .presentationBackground(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.displayCategories,
                    accounts: dataStore.accounts
                ) {
                    dataStore.rebuildCaches()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showBankImport) {
                NavigationStack {
                    BankImportView()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showReceiptScanner) {
                ReceiptScannerView {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
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
            Button {
                showAddAccount = true
            } label: {
                Label(String(localized: "home.addAccount"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
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
                            try await accountRepo.setPrimary(id: account.id)
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

// MARK: - Reports Shortcut Card

private struct ReportsShortcutCard: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accent, Color.accent.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "home.reports.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(localized: "home.reports.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Shared Account Shortcut Card

private struct SharedAccountShortcutCard: View {
    let account: Account

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: account.color), Color(hex: account.color).opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "sharedAccount.openDetail"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(localized: "settlement.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Challenges Shortcut Card

private struct ChallengesShortcutCard: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#F59E0B"), Color(hex: "#EF4444")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "flag.checkered")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "challenges.title"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "challenges.home.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Journal Shortcut Card

private struct JournalShortcutView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let gradient = LinearGradient(
        colors: [Color.aiGradientStart, Color.aiGradientEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        HStack(spacing: 16) {
            // Icon container
            ZStack {
                Circle()
                    .fill(gradient)
                    .frame(width: 52, height: 52)
                    .shadow(color: Color.aiGradientStart.opacity(0.45), radius: 8, x: 0, y: 4)

                Image(systemName: "book.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            // Text block
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(localized: "home.journal"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    // BETA badge — outlined capsule with gradient stroke
                    Text("BETA")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.aiGradientStart, Color.aiGradientEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.aiGradientStart, Color.aiGradientEnd],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                }

                Text(String(localized: "home.journal.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Navigation hint
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.aiGradientStart, Color.aiGradientEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(8)
                .background(
                    Circle()
                        .fill(Color.aiGradientStart.opacity(colorScheme == .dark ? 0.20 : 0.10))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 76)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.aiGradientStart.opacity(colorScheme == .dark ? 0.50 : 0.30),
                                    Color.aiGradientEnd.opacity(colorScheme == .dark ? 0.35 : 0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: Color.aiGradientStart.opacity(colorScheme == .dark ? 0.18 : 0.12),
                    radius: 12,
                    x: 0,
                    y: 6
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
