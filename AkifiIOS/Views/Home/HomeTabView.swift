import SwiftUI

struct HomeTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = HomeViewModel()
    @State private var showAddTransaction = false
    @State private var showAssistant = false

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !dataStore.accounts.isEmpty {
                        AccountCarouselView(
                            accounts: dataStore.accounts,
                            selectedIndex: $viewModel.selectedAccountIndex,
                            balanceFor: dataStore.balance
                        )
                    }

                    SummaryCardsView(
                        transactions: dataStore.recentTransactions,
                        selectedAccount: viewModel.selectedAccount(from: dataStore.accounts)
                    )

                    RecentTransactionsView(
                        transactions: dataStore.recentTransactions,
                        categories: dataStore.categories
                    )

                    // Quick access
                    HomeSavingsSnapshotView()
                }
                .padding(.horizontal)
            }
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle("Akifi")
            .toolbar {
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
        }
    }
}
