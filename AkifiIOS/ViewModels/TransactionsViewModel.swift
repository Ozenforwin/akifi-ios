import Foundation

@Observable @MainActor
final class TransactionsViewModel {
    var transactions: [Transaction] = []
    var categories: [Category] = []
    var isLoading = false
    var error: String?
    var selectedAccountId: String?

    private let transactionRepo = TransactionRepository()
    private let categoryRepo = CategoryRepository()

    func load() async {
        isLoading = true
        do {
            async let txs = transactionRepo.fetchAll(accountId: selectedAccountId)
            async let cats = categoryRepo.fetchAll()
            transactions = try await txs
            categories = try await cats
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func category(for transaction: Transaction) -> Category? {
        guard let categoryId = transaction.categoryId else { return nil }
        return categories.first { $0.id == categoryId }
    }

    func deleteTransaction(_ transaction: Transaction) async {
        do {
            try await transactionRepo.delete(id: transaction.id)
            transactions.removeAll { $0.id == transaction.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
