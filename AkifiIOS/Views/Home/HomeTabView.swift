import SwiftUI

struct HomeTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = HomeViewModel()
    @State private var showAddAccount = false
    @State private var showProfile = false
    @State private var showCurrencyPicker = false
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
                                .background(Color(.systemBackground))
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Поиск")
                }
            }
            .sheet(isPresented: $showProfile) {
                SettingsView()
            }
            .sheet(isPresented: $showCurrencyPicker) {
                NavigationStack {
                    CurrencyPickerView()
                }
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
