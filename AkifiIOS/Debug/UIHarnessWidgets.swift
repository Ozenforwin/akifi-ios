#if DEBUG
import Foundation
import WidgetKit

/// `-AkifiUIHarness -AkifiUIHarnessWidgets`: a fixture for the 1.6.0
/// widgets — accounts and categories with UUID ids (a quick-add link only
/// carries UUIDs), this month's rows and «Повторить» history — written
/// into the App Group snapshot, so the real «Счёт» / «Быстрая запись»
/// widgets on a simulator show it and their taps can be tried
/// (`xcrun simctl openurl <id> "akifi://quick-add?mode=expense&source=widget&account=<cardId>"`).
/// No network: the snapshot is saved directly, without the budget refresh.
enum UIHarnessWidgets {
    static var isEnabled: Bool {
        UIHarness.isEnabled && ProcessInfo.processInfo.arguments.contains("-AkifiUIHarnessWidgets")
    }

    static let cardId = "5a1d0000-0000-4000-8000-000000000001"
    static let cashId = "5a1d0000-0000-4000-8000-000000000002"
    static let usdId = "5a1d0000-0000-4000-8000-000000000003"
    static let familyId = "5a1d0000-0000-4000-8000-000000000004"

    private static func category(_ n: Int, _ name: String, _ icon: String, _ type: CategoryType = .expense) -> Category {
        Category(id: "5a1dca70-0000-4000-8000-00000000000\(n)", userId: "demo", accountId: nil, name: name, icon: icon,
                 color: "#3B82F6", type: type, isActive: true, createdAt: "2026-01-01T00:00:00Z")
    }

    @MainActor
    static func install(in store: DataStore, currencyManager: CurrencyManager) {
        let cafe = category(1, "Кафе", "☕️")
        let food = category(2, "Продукты", "🛒")
        let taxi = category(3, "Такси", "🚕")
        let salary = category(4, "Зарплата", "💼", .income)
        store.allAccounts = [
            Account(id: cardId, userId: "demo", name: "Тинькофф", icon: "💳", color: "#3B82F6",
                    initialBalance: 60_000_00, isPrimary: true, currency: "rub"),
            Account(id: cashId, userId: "demo", name: "Наличные", icon: "💵", color: "#10B981",
                    initialBalance: 6_200_00, currency: "rub", accountType: .cash),
            Account(id: usdId, userId: "demo", name: "ByBit", icon: "🪙", color: "#F59E0B",
                    initialBalance: 1_263_25, currency: "usd", accountType: .investment),
            Account(id: familyId, userId: "partner", name: "Семейный", icon: "👪", color: "#8B5CF6",
                    initialBalance: 40_000_00, currency: "rub"),
        ]
        store.categories = [cafe, food, taxi, salary]

        let calendar = AppDateFormatters.localCalendar
        let now = Date()
        func row(_ id: String, _ account: String, _ type: TransactionType, _ minor: Int64, daysAgo: Int, hour: Int,
                 _ description: String?, _ category: Category?) -> Transaction {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            let date = AppDateFormatters.isoDate.string(from: day)
            let raw = "\(date)T\(String(format: "%02d", hour)):00:00"
            return Transaction(id: "harness-w-\(id)", userId: "demo", accountId: account, amount: minor, currency: nil,
                               description: description, categoryId: category?.id, type: type, date: date, rawDateTime: raw,
                               merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
                               status: nil, createdAt: raw, updatedAt: nil)
        }
        store.transactions = [
            row("1", cardId, .expense, 250_00, daysAgo: 0, hour: 9, "Кофе", cafe),
            row("2", cardId, .expense, 1_840_00, daysAgo: 1, hour: 19, "Пятёрочка", food),
            row("3", cashId, .expense, 420_00, daysAgo: 1, hour: 8, "Такси", taxi),
            row("4", cardId, .expense, 250_00, daysAgo: 2, hour: 9, "Кофе", cafe),
            row("5", usdId, .expense, 12_50, daysAgo: 3, hour: 7, "Netflix", nil),
            row("6", cardId, .income, 120_000_00, daysAgo: 5, hour: 10, nil, salary),
            row("7", cardId, .expense, 3_460_00, daysAgo: 6, hour: 20, "Ашан", food),
        ]
        store.rebuildCaches()
        store.currencyContextDidChange()

        let snapshot = SharedSnapshotWriter.buildSnapshot(dataStore: store, currencyManager: currencyManager)
        do {
            try SharedSnapshotStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            AppLogger.data.warning("UI harness: widget snapshot not saved: \(error.localizedDescription)")
        }
    }
}
#endif
