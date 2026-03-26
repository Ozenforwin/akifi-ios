import SwiftUI

struct SearchView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var dataStore: DataStore { appViewModel.dataStore }

    private var results: [Transaction] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return dataStore.transactions.filter { tx in
            tx.description?.lowercased().contains(query) == true ||
            tx.merchantName?.lowercased().contains(query) == true ||
            dataStore.category(for: tx)?.name.lowercased().contains(query) == true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Поиск по описанию, продавцу или категории")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(results) { transaction in
                        TransactionRowView(
                            transaction: transaction,
                            category: dataStore.category(for: transaction)
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, isPresented: .constant(true), prompt: "Поиск операций")
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}
