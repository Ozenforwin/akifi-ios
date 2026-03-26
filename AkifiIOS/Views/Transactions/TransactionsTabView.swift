import SwiftUI

struct TransactionsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = TransactionsViewModel()
    @State private var showAddTransaction = false

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        @Bindable var vm = viewModel
        NavigationStack {
            List {
                ForEach(viewModel.filteredTransactions(from: dataStore.transactions)) { transaction in
                    TransactionRowView(
                        transaction: transaction,
                        category: dataStore.category(for: transaction)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await dataStore.deleteTransaction(transaction) }
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $vm.searchText, prompt: "Поиск операций")
            .refreshable {
                await dataStore.loadAll()
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
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts
                ) {
                    await dataStore.loadAll()
                }
            }
        }
    }
}
