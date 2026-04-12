import Foundation
import os

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

    private let cache = PersistenceManager.shared

    func loadAll() async {
        isLoading = true
        error = nil

        // 1. Load from offline cache first (instant)
        loadFromCache()
        rebuildCaches()

        // 2. Fetch fresh data from network
        var errors: [String] = []

        async let accountsFetch = accountRepo.fetchAll()
        async let txFetch = transactionRepo.fetchAll()
        async let catsFetch = categoryRepo.fetchAll()
        async let budgetsFetch = budgetRepo.fetchAll()
        async let subsFetch = subscriptionRepo.fetchAll()
        async let profileFetch = profileRepo.fetch()

        do { accounts = try await accountsFetch }
        catch { AppLogger.data.warning("accounts: \(error)"); errors.append("accounts") }

        do { transactions = try await txFetch }
        catch { AppLogger.data.warning("transactions: \(error)"); errors.append("transactions") }

        do { categories = try await catsFetch }
        catch { AppLogger.data.warning("categories: \(error)"); errors.append("categories") }

        do { budgets = try await budgetsFetch }
        catch { AppLogger.data.warning("budgets: \(error)"); errors.append("budgets") }

        do { subscriptions = try await subsFetch }
        catch { AppLogger.data.warning("subscriptions: \(error)"); errors.append("subscriptions") }

        do { profile = try await profileFetch }
        catch { AppLogger.data.debug("profile: \(error)") }

        // Sequential: depends on transactions & profile being loaded
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
            AppLogger.data.debug("profiles map: \(error)")
        }

        if !errors.isEmpty {
            self.error = errors.joined(separator: "; ")
            AppLogger.data.warning("Load completed with errors: \(self.error!)")
        }

        // 3. Save fresh data to offline cache
        saveToCache()
        rebuildCaches()
        isLoading = false
    }

    // MARK: - Offline Cache

    private func loadFromCache() {
        if let cached = cache.loadAccounts(), !cached.isEmpty { accounts = cached }
        if let cached = cache.loadTransactions(), !cached.isEmpty { transactions = cached }
        if let cached = cache.loadCategories(), !cached.isEmpty { categories = cached }
        if let cached = cache.loadBudgets(), !cached.isEmpty { budgets = cached }
        if let cached = cache.loadSubscriptions(), !cached.isEmpty { subscriptions = cached }
        if let cached = cache.loadProfile() { profile = cached }
    }

    private func saveToCache() {
        cache.saveAccounts(accounts)
        cache.saveTransactions(transactions)
        cache.saveCategories(categories)
        cache.saveBudgets(budgets)
        cache.saveSubscriptions(subscriptions)
        if let profile { cache.saveProfile(profile) }
    }

    func addTransaction(_ input: CreateTransactionInput) async throws -> Transaction {
        let tx = try await transactionRepo.create(input)
        transactions.insert(tx, at: 0)
        rebuildCaches()
        AnalyticsService.logAddTransaction(
            type: input.type,
            amount: Double(truncating: input.amount as NSDecimalNumber),
            category: input.category_id
        )
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
            AnalyticsService.logDeleteTransaction()
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

    // MARK: - Assistant Context

    /// Convert internal kopeck value (Int64) to whole currency units (Double).
    private func toUnits(_ kopecks: Int64) -> Double {
        Double(kopecks) / 100.0
    }

    func buildAssistantContext() -> AssistantContext {
        // Build category name lookup for human-readable keys
        let categoryNameById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        // Build account name lookup
        let accountNameById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })

        let accountSummaries = accounts.map { account in
            AssistantContext.AccountSummary(
                id: account.id,
                name: account.name,
                icon: account.icon,
                balance: toUnits(balance(for: account)),
                income: toUnits(accountIncome[account.id] ?? 0),
                expense: toUnits(accountExpense[account.id] ?? 0),
                currency: account.currency
            )
        }

        let categorySummaries = categories.map { cat in
            AssistantContext.CategorySummary(
                id: cat.id,
                name: cat.name,
                icon: cat.icon,
                type: cat.type.rawValue
            )
        }

        // Per-category expense totals (use category names as keys for LLM readability)
        var byCategoryKopecks: [String: Int64] = [:]
        var totalExpenseKopecks: Int64 = 0
        var totalIncomeKopecks: Int64 = 0
        for tx in transactions {
            switch tx.type {
            case .expense:
                totalExpenseKopecks += tx.amount
                if let catId = tx.categoryId {
                    let name = categoryNameById[catId] ?? catId
                    byCategoryKopecks[name, default: 0] += tx.amount
                }
            case .income:
                totalIncomeKopecks += tx.amount
            case .transfer:
                break
            }
        }

        // Per-account expense totals (use account names as keys for LLM readability)
        var byAccountKopecks: [String: Int64] = [:]
        for tx in transactions where tx.type == .expense {
            if let accId = tx.accountId {
                let name = accountNameById[accId] ?? accId
                byAccountKopecks[name, default: 0] += tx.amount
            }
        }

        // Convert to whole currency units
        let byCategory = byCategoryKopecks.mapValues { toUnits($0) }
        let byAccount = byAccountKopecks.mapValues { toUnits($0) }

        // Date range
        let dates = transactions.map(\.date).sorted()
        let dateFrom = dates.first
        let dateTo = dates.last

        let summary = AssistantContext.TransactionSummary(
            totalExpense: toUnits(totalExpenseKopecks),
            totalIncome: toUnits(totalIncomeKopecks),
            byCategory: byCategory,
            byAccount: byAccount,
            count: transactions.count,
            dateFrom: dateFrom,
            dateTo: dateTo
        )

        // Total balance across all accounts
        let totalBalance = accounts.reduce(0.0) { sum, account in
            sum + toUnits(balance(for: account))
        }

        let currencyLabel: String
        switch (accounts.first?.currency ?? "rub").lowercased() {
        case "rub": currencyLabel = "rubles"
        case "usd": currencyLabel = "US dollars"
        case "eur": currencyLabel = "euros"
        default: currencyLabel = accounts.first?.currency ?? "rubles"
        }

        return AssistantContext(
            accounts: accountSummaries,
            categories: categorySummaries,
            transactionSummary: summary,
            totalBalance: totalBalance,
            currency: accounts.first?.currency ?? "rub",
            locale: Locale.current.identifier,
            amountUnit: "All monetary amounts are in whole \(currencyLabel) (NOT kopecks/cents). For example, 1500 means 1500 \(currencyLabel)."
        )
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
                // Legacy transfer type — treat positive as income, negative as expense
                if tx.amount > 0 {
                    incomeByAccount[accountId, default: 0] += tx.amount
                } else {
                    expenseByAccount[accountId, default: 0] += abs(tx.amount)
                }
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

        // Deduplicate categories (shared accounts may return same category multiple times)
        var seen: Set<String> = []
        categories = categories.filter { cat in
            let key = "\(cat.name.lowercased())_\(cat.type.rawValue)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        categoryIndex = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }
}
