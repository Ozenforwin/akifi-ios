import SwiftUI

struct HomeTabView: View {
    @State private var viewModel = HomeViewModel()
    @State private var showAddTransaction = false
    @State private var showAssistant = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Account Carousel
                    if !viewModel.accounts.isEmpty {
                        AccountCarouselView(
                            accounts: viewModel.accounts,
                            selectedIndex: $viewModel.selectedAccountIndex,
                            balanceFor: viewModel.accountBalance
                        )
                    }

                    // Summary Cards
                    SummaryCardsView(
                        transactions: viewModel.recentTransactions,
                        selectedAccount: viewModel.selectedAccount
                    )

                    // Recent Transactions
                    RecentTransactionsView(
                        transactions: viewModel.recentTransactions,
                        categories: viewModel.categories
                    )
                }
                .padding(.horizontal)
            }
            .refreshable {
                await viewModel.load()
            }
            .navigationTitle("Akifi")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAssistant = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddTransaction = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task {
                await viewModel.load()
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(categories: viewModel.categories, accounts: viewModel.accounts) {
                    await viewModel.load()
                }
            }
            .fullScreenCover(isPresented: $showAssistant) {
                AssistantView()
            }
        }
    }
}
