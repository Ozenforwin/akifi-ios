import Foundation

@Observable @MainActor
final class HomeViewModel {
    var accounts: [Account] = []
    var recentTransactions: [Transaction] = []
    var categories: [Category] = []
    var selectedAccountIndex: Int = 0
    var isLoading = false
    var error: String?

    private let accountRepo = AccountRepository()
    private let transactionRepo = TransactionRepository()
    private let categoryRepo = CategoryRepository()

    var selectedAccount: Account? {
        guard accounts.indices.contains(selectedAccountIndex) else { return nil }
        return accounts[selectedAccountIndex]
    }

    func load() async {
        isLoading = true
        error = nil

        do {
            async let fetchedAccounts = accountRepo.fetchAll()
            async let fetchedCategories = categoryRepo.fetchAll()

            accounts = try await fetchedAccounts
            categories = try await fetchedCategories

            let txs = try await transactionRepo.fetchAll()
            recentTransactions = Array(txs.prefix(10))
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func accountBalance(for account: Account) -> Int64 {
        let income = recentTransactions
            .filter { $0.accountId == account.id && $0.type == .income }
            .reduce(Int64(0)) { $0 + $1.amount }
        let expense = recentTransactions
            .filter { $0.accountId == account.id && $0.type == .expense }
            .reduce(Int64(0)) { $0 + $1.amount }
        return account.initialBalance + income - expense
    }
}
