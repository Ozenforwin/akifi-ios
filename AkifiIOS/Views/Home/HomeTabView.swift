import SwiftUI

struct HomeTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = HomeViewModel()
    @State private var showAddTransaction = false
    @State private var showAssistant = false
    @State private var showAddAccount = false
    @State private var showShareAccount = false
    @State private var showSearch = false
    @State private var editingAccount: Account?

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if dataStore.accounts.isEmpty {
                        Button {
                            showAddAccount = true
                        } label: {
                            Label("Добавить счёт", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        }
                    } else {
                        AccountCarouselView(
                            accounts: dataStore.accounts,
                            selectedIndex: $viewModel.selectedAccountIndex,
                            balanceFor: dataStore.balance
                        )
                        .contextMenu {
                            Button {
                                showAddAccount = true
                            } label: {
                                Label("Новый счёт", systemImage: "plus")
                            }
                            if let account = viewModel.selectedAccount(from: dataStore.accounts) {
                                Button {
                                    editingAccount = account
                                } label: {
                                    Label("Редактировать", systemImage: "pencil")
                                }
                                Button {
                                    showShareAccount = true
                                } label: {
                                    Label("Поделиться", systemImage: "person.badge.plus")
                                }
                            }
                        }
                    }

                    SummaryCardsView(
                        transactions: dataStore.recentTransactions,
                        selectedAccount: viewModel.selectedAccount(from: dataStore.accounts)
                    )

                    RecentTransactionsView(
                        transactions: dataStore.recentTransactions,
                        categories: dataStore.categories
                    )

                    // Streak & Insights
                    StreakBadgeView()
                    InsightCardsView()

                    // Savings
                    HomeSavingsSnapshotView()
                }
                .padding(.horizontal)
            }
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle("Akifi")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Поиск")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAssistant = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("AI-ассистент")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddTransaction = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Добавить операцию")
                }
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(categories: dataStore.categories, accounts: dataStore.accounts) {
                    await dataStore.loadAll()
                }
            }
            .fullScreenCover(isPresented: $showAssistant) {
                AssistantView()
            }
            .sheet(isPresented: $showAddAccount) {
                AccountFormView {
                    await dataStore.loadAll()
                }
            }
            .sheet(isPresented: $showShareAccount) {
                if let account = viewModel.selectedAccount(from: dataStore.accounts) {
                    ShareAccountView(account: account)
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
            }
            .sheet(item: $editingAccount) { account in
                AccountFormView(editingAccount: account) {
                    await dataStore.loadAll()
                }
            }
        }
    }
}
