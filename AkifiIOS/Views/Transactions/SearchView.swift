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
                    ContentUnavailableView {
                        Label(String(localized: "search.title"), systemImage: "magnifyingglass")
                    } description: {
                        Text(String(localized: "search.hint"))
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(results) { transaction in
                        TransactionRowView(
                            transaction: transaction,
                            category: dataStore.category(for: transaction)
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .searchable(text: $searchText, isPresented: .constant(true), prompt: String(localized: "search.prompt"))
            .navigationTitle(String(localized: "search.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
    }
}
