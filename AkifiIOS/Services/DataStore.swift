import Foundation

@Observable @MainActor
final class DataStore {
    var accounts: [Account] = []
    var transactions: [Transaction] = []
    var categories: [Category] = []
    var isLoading = false
    var error: String?

    private var balanceCache: [String: Int64] = [:]
    private var categoryIndex: [String: Category] = [:]
    // Pre-computed per-account income/expense for cards
    private(set) var accountIncome: [String: Int64] = [:]
    private(set) var accountExpense: [String: Int64] = [:]

    private let accountRepo = AccountRepository()
    private let transactionRepo = TransactionRepository()
    private let categoryRepo = CategoryRepository()
    private let budgetRepo = BudgetRepository()
    private let subscriptionRepo = SubscriptionTrackerRepository()
    private let profileRepo = ProfileRepository()

    var budgets: [Budget] = []
    var subscriptions: [SubscriptionTracker] = []
    var profile: Profile?
    var profilesMap: [String: Profile] = [:]

    func loadAll() async {
        isLoading = true
        error = nil
        var errors: [String] = []

        do {
            accounts = try await accountRepo.fetchAll()
        } catch {
            // print("[DataStore] ❌ accounts fetch error: \(error)")
            errors.append("accounts: \(error)")
        }

        do {
            transactions = try await transactionRepo.fetchAll()
        } catch {
            // print("[DataStore] ❌ transactions fetch error: \(error)")
            errors.append("transactions: \(error)")
        }

        do {
            categories = try await categoryRepo.fetchAll()
        } catch {
            // print("[DataStore] ❌ categories fetch error: \(error)")
            errors.append("categories: \(error)")
        }

        do {
            budgets = try await budgetRepo.fetchAll()
        } catch {
            // print("[DataStore] ❌ budgets fetch error: \(error)")
            errors.append("budgets: \(error)")
        }

        do {
            subscriptions = try await subscriptionRepo.fetchAll()
        } catch {
            // print("[DataStore] ❌ subscriptions fetch error: \(error)")
            errors.append("subscriptions: \(error)")
        }

        do {
            profile = try await profileRepo.fetch()
        } catch {
            // print("[DataStore] ❌ profile fetch error: \(error)")
        }

        // Load profiles for transaction creators (shared accounts)
        do {
            let currentUserId = profile?.id ?? ""
            let otherUserIds = Array(Set(transactions.map(\.userId)).filter { $0 != currentUserId })
            if !otherUserIds.isEmpty {
                let otherProfiles = try await profileRepo.fetchAll(ids: otherUserIds)
                for p in otherProfiles {
                    profilesMap[p.id] = p
                }
            }
            if let profile { profilesMap[profile.id] = profile }
        } catch {
            // print("[DataStore] ❌ profiles map fetch error: \(error)")
        }

        if !errors.isEmpty {
            self.error = errors.joined(separator: "; ")
            // print("[DataStore] ⚠️ Load completed with errors: \(self.error!)")
        } else {
            // print("[DataStore] ✅ All data loaded")
        }
        rebuildCaches()
        isLoading = false
    }

    func addTransaction(_ input: CreateTransactionInput) async throws -> Transaction {
        let tx = try await transactionRepo.create(input)
        transactions.insert(tx, at: 0)
        rebuildCaches()
        return tx
    }

    func updateTransaction(id: String, _ input: UpdateTransactionInput) async throws {
        try await transactionRepo.update(id: id, input)
        // Reload only transactions instead of all data
        do {
            transactions = try await transactionRepo.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteTransaction(_ transaction: Transaction) async {
        do {
            try await transactionRepo.delete(id: transaction.id)
            transactions.removeAll { $0.id == transaction.id }
            rebuildCaches()
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

    /// Rebuild all caches in one pass — call after any data change
    func rebuildCaches() {
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
        accountIncome = incomeByAccount
        accountExpense = expenseByAccount
        categoryIndex = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }
}
