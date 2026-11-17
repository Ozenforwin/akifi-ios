import XCTest
import SwiftUI
import UIKit
@testable import AkifiIOS

/// P2: what a refresh that brings NOTHING new costs the main thread once
/// the four main tabs are alive (MainTabView keeps visited tabs mounted).
/// That is the common case — pull-to-refresh, every form save, returning
/// to the foreground — and it used to re-render every tab, because
/// `loadAll` / `rebuildCaches` reassigned every observed property whether
/// or not it changed.
///
/// `refresh.unchanged.unconditionalWrites` replays the old write pattern
/// (every collection reassigned, every derived cache rewritten);
/// `refresh.unchanged.skipEqual` is the current `loadAll()` against a
/// server that returns exactly what's on screen.
///
/// Run: `TEST_RUNNER_AKIFI_BENCH=1 xcodebuild test … -only-testing:AkifiIOSTests/RefreshRenderBenchmarkTests`
/// Prints `BENCH|<name>|<median ms>|<min ms>|<max ms>`.
@MainActor
final class RefreshRenderBenchmarkTests: XCTestCase {

    private func requireBenchmarkRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AKIFI_BENCH"] == "1",
                          "set TEST_RUNNER_AKIFI_BENCH=1 to run benchmarks")
    }

    private func report(_ name: String, _ samples: [Double]) {
        let s = samples.sorted()
        print(String(format: "BENCH|%@|%.1f|%.1f|%.1f", name, s[s.count / 2], s.first!, s.last!))
    }

    private func time(_ block: () -> Void) -> Double {
        let t0 = CACurrentMediaTime()
        block()
        return (CACurrentMediaTime() - t0) * 1000
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Production-sized data (same shape as `TabOpenBenchmarkTests`):
    /// ~1 300 transactions over 7 months, 10 accounts, 40 categories,
    /// 8 budgets, 12 subscriptions.
    private func makeApp(persistence: PersistenceManager) -> AppViewModel {
        let store = DataStore(cache: persistence)
        let app = AppViewModel(dataStore: store)
        app.currencyManager.rates = ["USD": 1, "RUB": 92.5, "EUR": 0.92, "VND": 25_400]
        let currencies = ["rub", "rub", "usd", "usd", "rub", "usd", "rub", "rub", "eur", "vnd"]
        var accounts: [Account] = []
        for (i, ccy) in currencies.enumerated() {
            let initial = Int64(10_000_00) + Int64(i) * Int64(1_000_00)
            accounts.append(Account(id: "acc-\(i)", userId: "me", name: "Счёт \(i)", icon: "💳", color: "#3B82F6",
                                    initialBalance: initial, currency: ccy))
        }
        var categories: [AkifiIOS.Category] = []
        for i in 0..<40 {
            let type: CategoryType = i < 32 ? .expense : .income
            categories.append(AkifiIOS.Category(id: "cat-\(i)", userId: "me", accountId: nil, name: "Категория \(i % 30)",
                                                icon: "🛒", color: "#22C55E", type: type,
                                                isActive: true, createdAt: nil))
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        let now = Date()
        var txs: [AkifiIOS.Transaction] = []
        for i in 0..<1_300 {
            let when = now.addingTimeInterval(-Double(i) * 210 * 86_400 / 1_300)
            let account = accounts[i % accounts.count]
            let isIncome = i % 11 == 0
            let amount = Int64(100_00) + Int64((i * 37) % 1_500_000)
            let categoryIndex = isIncome ? 32 + i % 8 : i % 32
            let type: TransactionType = isIncome ? .income : .expense
            let date = day.string(from: when)
            txs.append(AkifiIOS.Transaction(
                id: "t-\(i)", userId: "me", accountId: account.id, amount: amount,
                currency: account.currency.uppercased(), description: "Покупка \(i)",
                categoryId: "cat-\(categoryIndex)", type: type,
                date: date, rawDateTime: date + "T10:00:00",
                merchantName: "Магазин \(i % 60)", merchantFuzzy: nil, transferGroupId: nil,
                status: nil, createdAt: nil, updatedAt: nil
            ))
        }
        var budgets: [Budget] = []
        for b in 0..<8 {
            let limit = Int64(20_000_00) + Int64(b) * Int64(5_000_00)
            let period: BillingPeriod = b == 7 ? .weekly : .monthly
            let cats: [String] = ["cat-\(b)", "cat-\(b + 8)"]
            let ccy: String = b == 6 ? "USD" : "RUB"
            budgets.append(Budget(id: "b-\(b)", userId: "me", budgetName: "Бюджет \(b)", amount: limit,
                                  billingPeriod: period, categoryIds: cats, currency: ccy))
        }
        var subs: [SubscriptionTracker] = []
        for s in 0..<12 {
            let price = Int64(299_00) + Int64(s) * Int64(100_00)
            let ccy: String = s % 3 == 0 ? "USD" : "RUB"
            let start: String = day.string(from: now.addingTimeInterval(-Double(s) * 20 * 86_400))
            let next: String = day.string(from: now.addingTimeInterval(Double(s) * 2 * 86_400))
            subs.append(SubscriptionTracker(id: "s-\(s)", userId: "me", serviceName: "Сервис \(s)", amount: price,
                                            currency: ccy, billingPeriod: .monthly, startDate: start,
                                            nextPaymentDate: next))
        }
        store.accounts = accounts
        store.categories = categories
        store.transactions = txs
        store.budgets = budgets
        store.subscriptions = subs
        store.rebuildCaches()
        store.currencyContextDidChange()
        return app
    }

    private let tabs: [() -> AnyView] = [
        { AnyView(HomeTabView()) },
        { AnyView(TransactionsTabView()) },
        { AnyView(AnalyticsTabView()) },
        { AnyView(BudgetsTabView()) },
    ]

    private func mountAll(_ app: AppViewModel) -> [(UIWindow, UIHostingController<AnyView>)] {
        tabs.map { make in
            let host = UIHostingController(rootView: AnyView(make().environment(app).environment(CurrentAccountContext())))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            return (window, host)
        }
    }

    private func relayout(_ windows: [(UIWindow, UIHostingController<AnyView>)]) -> Double {
        time {
            for w in windows { w.1.view.setNeedsLayout(); w.1.view.layoutIfNeeded() }
        }
    }

    func test_bench_unchangedRefresh_allVisitedTabs() async throws {
        try requireBenchmarkRun()
        var oldPattern: [Double] = []
        var skipEqual: [Double] = []
        for _ in 0..<5 {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Bench-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let app = makeApp(persistence: PersistenceManager(directory: dir))
            let store = app.dataStore
            let windows = mountAll(app)
            spin(0.3)

            // Old write pattern: every collection reassigned (equal values),
            // every derived cache rewritten.
            store.accounts = store.accounts
            store.transactions = store.transactions
            store.categories = store.categories
            store.budgets = store.budgets
            store.subscriptions = store.subscriptions
            store.currencyContextDidChange()
            oldPattern.append(relayout(windows))
            spin(0.5)

            // Current loadAll() against a server returning what's on screen.
            var same = RemoteFetchResult()
            same.accounts = store.accounts
            same.transactions = store.transactions
            same.categories = store.categories
            same.budgets = store.budgets
            same.subscriptions = store.subscriptions
            same.budgetMembersByBudget = store.budgetMembersByBudget
            same.profilesMap = store.profilesMap
            let result = same
            store.isConnectedProvider = { true }
            store.sessionValidator = { true }
            store.localSessionPresent = { true }
            store.remote.fetchAll = { _ in result }
            await store.loadAll()
            skipEqual.append(relayout(windows))

            windows.forEach { $0.0.isHidden = true }
        }
        report("refresh.unchanged.unconditionalWrites", oldPattern)
        report("refresh.unchanged.skipEqual", skipEqual)
    }
}
