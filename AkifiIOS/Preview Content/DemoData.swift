import Foundation

/// Realistic mock data for the new-user welcome overlay.
/// Dates are relative to now so the data always looks fresh.
enum DemoData {
    // MARK: - Helpers

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func daysAgo(_ n: Int) -> String {
        df.string(from: Calendar.current.date(byAdding: .day, value: -n, to: Date())!)
    }

    // MARK: - Accounts

    static let accounts: [Account] = [
        Account(id: "demo-acc-1", userId: "demo", name: "Chase Checking",
                icon: "🏦", color: "#60A5FA", initialBalance: 87_350_00,
                isPrimary: true, currency: "rub"),
        Account(id: "demo-acc-2", userId: "demo", name: "Savings",
                icon: "💰", color: "#A78BFA", initialBalance: 250_000_00,
                currency: "rub"),
    ]

    // MARK: - Categories

    static let catFood = Category(id: "demo-cat-1", userId: "demo", accountId: nil,
        name: "Groceries", icon: "🛒", color: "#F472B6", type: .expense, isActive: true, createdAt: "2025-01-01")
    static let catTransport = Category(id: "demo-cat-2", userId: "demo", accountId: nil,
        name: "Transport", icon: "🚕", color: "#FBBF24", type: .expense, isActive: true, createdAt: "2025-01-01")
    static let catCafe = Category(id: "demo-cat-3", userId: "demo", accountId: nil,
        name: "Coffee", icon: "☕", color: "#FB923C", type: .expense, isActive: true, createdAt: "2025-01-01")
    static let catEntertainment = Category(id: "demo-cat-4", userId: "demo", accountId: nil,
        name: "Entertainment", icon: "🎬", color: "#A78BFA", type: .expense, isActive: true, createdAt: "2025-01-01")
    static let catClothing = Category(id: "demo-cat-5", userId: "demo", accountId: nil,
        name: "Shopping", icon: "👕", color: "#38BDF8", type: .expense, isActive: true, createdAt: "2025-01-01")
    static let catSalary = Category(id: "demo-cat-6", userId: "demo", accountId: nil,
        name: "Salary", icon: "💰", color: "#4ADE80", type: .income, isActive: true, createdAt: "2025-01-01")

    static let categories: [Category] = [
        catFood, catTransport, catCafe, catEntertainment, catClothing, catSalary,
    ]

    // MARK: - Transactions

    static let transactions: [Transaction] = [
        Transaction(id: "demo-tx-1", userId: "demo", accountId: "demo-acc-1",
            amount: 4_870_00, currency: "RUB", description: "Weekly groceries",
            categoryId: "demo-cat-1", type: .expense, date: daysAgo(1),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(1), updatedAt: nil),

        Transaction(id: "demo-tx-2", userId: "demo", accountId: "demo-acc-1",
            amount: 520_00, currency: "RUB", description: "Espresso",
            categoryId: "demo-cat-3", type: .expense, date: daysAgo(1),
            merchantName: "Starbucks", merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(1), updatedAt: nil),

        Transaction(id: "demo-tx-3", userId: "demo", accountId: "demo-acc-1",
            amount: 890_00, currency: "RUB", description: nil,
            categoryId: "demo-cat-2", type: .expense, date: daysAgo(2),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(2), updatedAt: nil),

        Transaction(id: "demo-tx-4", userId: "demo", accountId: "demo-acc-1",
            amount: 2_350_00, currency: "RUB", description: "Groceries",
            categoryId: "demo-cat-1", type: .expense, date: daysAgo(3),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(3), updatedAt: nil),

        Transaction(id: "demo-tx-5", userId: "demo", accountId: "demo-acc-1",
            amount: 150_000_00, currency: "RUB", description: "Salary",
            categoryId: "demo-cat-6", type: .income, date: daysAgo(5),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(5), updatedAt: nil),

        Transaction(id: "demo-tx-6", userId: "demo", accountId: "demo-acc-1",
            amount: 1_990_00, currency: "RUB", description: "Cinema",
            categoryId: "demo-cat-4", type: .expense, date: daysAgo(6),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(6), updatedAt: nil),

        Transaction(id: "demo-tx-7", userId: "demo", accountId: "demo-acc-1",
            amount: 5_490_00, currency: "RUB", description: "T-shirt",
            categoryId: "demo-cat-5", type: .expense, date: daysAgo(8),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(8), updatedAt: nil),

        Transaction(id: "demo-tx-8", userId: "demo", accountId: "demo-acc-1",
            amount: 437_00, currency: "RUB", description: "Oat latte",
            categoryId: "demo-cat-3", type: .expense, date: daysAgo(9),
            merchantName: "Starbucks", merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(9), updatedAt: nil),

        Transaction(id: "demo-tx-9", userId: "demo", accountId: "demo-acc-1",
            amount: 3_200_00, currency: "RUB", description: "Groceries",
            categoryId: "demo-cat-1", type: .expense, date: daysAgo(11),
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: daysAgo(11), updatedAt: nil),
    ]

    // MARK: - Budget

    static let budget = Budget(
        id: "demo-budget-1", userId: "demo",
        budgetName: "Groceries", amount: 30_000_00,
        billingPeriod: .monthly, categoryIds: ["demo-cat-1"],
        alertThresholds: [80], isActive: true
    )

    // MARK: - Subscriptions

    static let subscriptions: [SubscriptionTracker] = [
        SubscriptionTracker(
            id: "demo-sub-1", userId: "demo",
            serviceName: "Netflix", amount: 799_00, currency: "RUB",
            billingPeriod: .monthly, startDate: daysAgo(45),
            nextPaymentDate: daysAgo(-12), reminderDays: 1,
            iconColor: "#E50914", isActive: true,
            createdAt: daysAgo(45), updatedAt: nil
        ),
        SubscriptionTracker(
            id: "demo-sub-2", userId: "demo",
            serviceName: "Spotify", amount: 299_00, currency: "RUB",
            billingPeriod: .monthly, startDate: daysAgo(30),
            nextPaymentDate: daysAgo(-5), reminderDays: 1,
            iconColor: "#1DB954", isActive: true,
            createdAt: daysAgo(30), updatedAt: nil
        ),
        SubscriptionTracker(
            id: "demo-sub-3", userId: "demo",
            serviceName: "iCloud+", amount: 99_00, currency: "RUB",
            billingPeriod: .monthly, startDate: daysAgo(60),
            nextPaymentDate: daysAgo(-20), reminderDays: 1,
            iconColor: "#007AFF", isActive: true,
            createdAt: daysAgo(60), updatedAt: nil
        ),
    ]
}
