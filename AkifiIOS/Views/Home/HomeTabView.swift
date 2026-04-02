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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // 0. Header
                    AppHeaderView(showProfile: $showProfile)

                    // 1. Account Carousel
                    accountSection

                    // 2. Streak
                    StreakBadgeView()

                    // 3. AI Insights
                    InsightCardsView()
                        .spotlight(.insightCards)

                    // 4. Savings
                    HomeSavingsSnapshotView()

                    // 5. Summary Cards
                    summarySection

                    // 6. Recent Transactions
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
                TransactionFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts,
                    editingTransaction: transaction
                ) {
                    await dataStore.loadAll()
                }
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts
                ) {
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
                transactions: dataStore.recentTransactions,
                categories: dataStore.categories,
                onEdit: { tx in editingTransaction = tx },
                onDelete: { tx in
                    Task { await dataStore.deleteTransaction(tx) }
                }
            )
        }
    }
}
