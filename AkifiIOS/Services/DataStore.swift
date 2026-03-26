import Foundation

@Observable @MainActor
final class DataStore {
    var accounts: [Account] = [] {
        didSet { rebuildBalanceCache() }
    }
    var transactions: [Transaction] = [] {
        didSet { rebuildBalanceCache() }
    }
    var categories: [Category] = [] {
        didSet { rebuildCategoryIndex() }
    }
    var isLoading = false
    var error: String?

    private var balanceCache: [String: Int64] = [:]
    private var categoryIndex: [String: Category] = [:]

    private let accountRepo = AccountRepository()
    private let transactionRepo = TransactionRepository()
    private let categoryRepo = CategoryRepository()

    func loadAll() async {
        isLoading = true
        error = nil
        do {
            async let a = accountRepo.fetchAll()
            async let t = transactionRepo.fetchAll()
            async let c = categoryRepo.fetchAll()
            accounts = try await a
            transactions = try await t
            categories = try await c
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func addTransaction(_ input: CreateTransactionInput) async throws -> Transaction {
        let tx = try await transactionRepo.create(input)
        transactions.insert(tx, at: 0)
        return tx
    }

    func updateTransaction(id: String, _ input: UpdateTransactionInput) async throws {
        try await transactionRepo.update(id: id, input)
        await loadAll()
    }

    func deleteTransaction(_ transaction: Transaction) async {
        do {
            try await transactionRepo.delete(id: transaction.id)
            transactions.removeAll { $0.id == transaction.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func category(for transaction: Transaction) -> Category? {
        guard let categoryId = transaction.categoryId else { return nil }
        return categoryIndex[categoryId]
    }

    func balance(for account: Account) -> Int64 {
        balanceCache[account.id] ?? account.initialBalance
    }

    var recentTransactions: [Transaction] {
        Array(transactions.prefix(10))
    }

    // MARK: - Cache

    private func rebuildBalanceCache() {
        var incomeByAccount: [String: Int64] = [:]
        var expenseByAccount: [String: Int64] = [:]

        for tx in transactions {
            guard let accountId = tx.accountId else { continue }
            switch tx.type {
            case .income:
                incomeByAccount[accountId, default: 0] += tx.amount
            case .expense:
                expenseByAccount[accountId, default: 0] += tx.amount
            case .transfer:
                break
            }
        }

        var cache: [String: Int64] = [:]
        for account in accounts {
            let income = incomeByAccount[account.id] ?? 0
            let expense = expenseByAccount[account.id] ?? 0
            cache[account.id] = account.initialBalance + income - expense
        }
        balanceCache = cache
    }

    private func rebuildCategoryIndex() {
        categoryIndex = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }
}
