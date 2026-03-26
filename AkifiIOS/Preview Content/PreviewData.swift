import Foundation

enum PreviewData {
    static let account = Account(
        id: "preview-account-1",
        userId: "preview-user",
        name: "Основной",
        icon: "💳",
        color: "#4ADE80",
        initialBalance: 150_000_00,
        createdAt: "2025-01-01"
    )

    static let account2 = Account(
        id: "preview-account-2",
        userId: "preview-user",
        name: "Накопления",
        icon: "🏦",
        color: "#60A5FA",
        initialBalance: 500_000_00,
        createdAt: "2025-01-01"
    )

    static let accounts = [account, account2]

    static let categoryFood = Category(
        id: "cat-food",
        userId: "preview-user",
        accountId: nil,
        name: "Еда",
        icon: "🛒",
        color: "#F472B6",
        type: .expense,
        isActive: true,
        createdAt: "2025-01-01"
    )

    static let categorySalary = Category(
        id: "cat-salary",
        userId: "preview-user",
        accountId: nil,
        name: "Зарплата",
        icon: "💰",
        color: "#4ADE80",
        type: .income,
        isActive: true,
        createdAt: "2025-01-01"
    )

    static let categories = [categoryFood, categorySalary]

    static let transaction1 = Transaction(
        id: "tx-1",
        userId: "preview-user",
        accountId: "preview-account-1",
        amount: 2500_00,
        currency: "RUB",
        description: "Продукты",
        categoryId: "cat-food",
        type: .expense,
        date: "2025-03-25",
        merchantName: "Перекрёсток",
        merchantFuzzy: nil,
        transferGroupId: nil,
        status: nil,
        createdAt: "2025-03-25",
        updatedAt: nil
    )

    static let transaction2 = Transaction(
        id: "tx-2",
        userId: "preview-user",
        accountId: "preview-account-1",
        amount: 100_000_00,
        currency: "RUB",
        description: "Зарплата",
        categoryId: "cat-salary",
        type: .income,
        date: "2025-03-20",
        merchantName: nil,
        merchantFuzzy: nil,
        transferGroupId: nil,
        status: nil,
        createdAt: "2025-03-20",
        updatedAt: nil
    )

    static let transactions = [transaction1, transaction2]

    static let budget = Budget(
        id: "budget-1",
        userId: "preview-user",
        accountId: nil,
        name: "Еда на месяц",
        amount: 30_000_00,
        currency: "RUB",
        billingPeriod: .monthly,
        categories: ["cat-food"],
        periodStart: nil,
        periodEnd: nil,
        rolloverEnabled: false,
        alertThreshold: 0.8,
        thresholdType: nil,
        isActive: true,
        createdAt: "2025-01-01",
        updatedAt: nil
    )

    static let savingsGoal = SavingsGoal(
        id: "goal-1",
        userId: "preview-user",
        name: "Отпуск",
        icon: "✈️",
        color: "#60A5FA",
        targetAmount: 200_000_00,
        currentAmount: 85_000_00,
        currency: "RUB",
        deadline: "2025-08-01",
        description: nil,
        accountId: nil,
        interestRate: nil,
        interestType: nil,
        interestCompound: nil,
        totalInterestEarned: nil,
        monthlyTarget: nil,
        reminderEnabled: false,
        reminderDay: nil,
        status: .active,
        completedAt: nil,
        priority: 0,
        createdAt: "2025-01-01",
        updatedAt: nil
    )

    static let achievement = Achievement(
        id: "ach-1",
        key: "first_transaction",
        category: .gettingStarted,
        nameRu: "Первый шаг",
        nameEn: "First Step",
        descriptionRu: "Создайте первую операцию",
        descriptionEn: nil,
        icon: "🎯",
        tier: .bronze,
        points: 10,
        conditionType: "transaction_count",
        conditionValue: 1,
        triggerType: nil,
        isSecret: false,
        sortOrder: 1
    )
}
