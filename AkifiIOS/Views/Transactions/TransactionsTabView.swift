import SwiftUI

struct TransactionsTabView: View {
    @State private var viewModel = TransactionsViewModel()
    @State private var showAddTransaction = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredTransactions) { transaction in
                    TransactionRowView(
                        transaction: transaction,
                        category: viewModel.category(for: transaction)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await viewModel.deleteTransaction(transaction) }
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Поиск операций")
            .refreshable {
                await viewModel.load()
            }
            .navigationTitle("Операции")
            .toolbar {
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
                TransactionFormView(
                    categories: viewModel.categories,
                    accounts: []
                ) {
                    await viewModel.load()
                }
            }
        }
    }

    private var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return viewModel.transactions
        }
        return viewModel.transactions.filter { tx in
            tx.description?.localizedCaseInsensitiveContains(searchText) == true ||
            tx.merchantName?.localizedCaseInsensitiveContains(searchText) == true
        }
    }
}
