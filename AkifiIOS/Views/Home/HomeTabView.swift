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

    private var dataStore: DataStore { appViewModel.dataStore }
    private let accountRepo = AccountRepository()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // 0. Header: avatar + name + currency + theme
                    AppHeaderView(showProfile: $showProfile)

                    // 1. Account Carousel
                    if dataStore.accounts.isEmpty {
                        Button {
                            showAddAccount = true
                        } label: {
                            Label("Добавить счёт", systemImage: "plus.circle.fill")
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
                                        // setPrimary error silently handled
                                    }
                                }
                            }
                        )
                    }

                    // 2. Streak
                    StreakBadgeView()

                    // 3. AI Insights
                    InsightCardsView()

                    // 4. Savings
                    HomeSavingsSnapshotView()

                    // 5. Summary Cards (income/expense) — all transactions, not just recent
                    SummaryCardsView(
                        transactions: dataStore.transactions,
                        selectedAccount: viewModel.selectedAccount(from: dataStore.accounts)
                    )

                    // 6. Recent Transactions
                    RecentTransactionsView(
                        transactions: dataStore.recentTransactions,
                        categories: dataStore.categories,
                        onEdit: { tx in editingTransaction = tx },
                        onDelete: { tx in
                            Task { await dataStore.deleteTransaction(tx) }
                        }
                    )
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .refreshable {
                await dataStore.loadAll()
            }
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
        }
    }
}
