import Foundation

@Observable @MainActor
final class TransactionsViewModel {
    var searchText = ""
    var selectedAccountId: String?

    func filteredTransactions(from transactions: [Transaction]) -> [Transaction] {
        var result = transactions
        if let accountId = selectedAccountId {
            result = result.filter { $0.accountId == accountId }
        }
        if !searchText.isEmpty {
            result = result.filter { tx in
                tx.description?.localizedCaseInsensitiveContains(searchText) == true ||
                tx.merchantName?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
        return result
    }
}
