import XCTest
import SwiftUI
import UIKit
@testable import AkifiIOS

/// CPU side of "tabs open slowly": how long the main thread is busy building
/// each tab, and how long a single data change keeps it busy re-rendering the
/// tabs the user has already visited (MainTabView keeps them alive).
/// Network is measured separately — none of these views get a session here,
/// so their `.task` fetches fail fast and don't count.
///
/// Dataset is sized like the main user's production data (2026-11): ~1 300
/// visible transactions over 7 months, 10 accounts (one shared RUB, USD cards),
/// 40 categories, 8 budgets, 12 subscriptions.
///
/// Run: `TEST_RUNNER_AKIFI_BENCH=1 xcodebuild test -scheme AkifiIOS -only-testing:AkifiIOSTests/TabOpenBenchmarkTests …`
/// Results are printed as `BENCH|<name>|<median ms>|<min ms>|<max ms>` so a
/// run can be grepped from xcodebuild output. Simulator on Apple silicon is
/// typically 1.5–3× faster than an iPhone for this kind of work.
@MainActor
final class TabOpenBenchmarkTests: XCTestCase {

    // MARK: - Fixture

    private static let me = "user-me"
    private static let partner = "user-partner"

    private static func makeApp(txCount: Int = 1_300) -> AppViewModel {
        let app = AppViewModel()
        let store = app.dataStore
        app.currencyManager.rates = ["USD": 1, "RUB": 92.5, "EUR": 0.92, "VND": 25_400]

        let shared = Account(id: "acc-shared", userId: me, name: "Семейный", icon: "💵", color: "#8B5CF6",
                             initialBalance: 101_222_00, currency: "rub")
        var accounts = [shared]
        let personal: [(String, String)] = [("Тинькофф", "rub"), ("IBT BANK", "usd"), ("ByBit", "usd"),
                                            ("Наличка", "rub"), ("Freedom", "usd"), ("Сбер", "rub"),
                                            ("Копилка", "rub"), ("EUR card", "eur"), ("VND cash", "vnd")]
        for (i, p) in personal.enumerated() {
            accounts.append(Account(id: "acc-\(i)", userId: me, name: p.0, icon: "💳", color: "#3B82F6",
                                    initialBalance: Int64(10_000_00 + i * 1_000_00), currency: p.1))
        }

        var categories: [AkifiIOS.Category] = []
        for i in 0..<40 {
            categories.append(AkifiIOS.Category(id: "cat-\(i)", userId: i % 5 == 0 ? partner : me, accountId: nil,
                                       name: "Категория \(i % 30)", icon: "🛒", color: "#22C55E",
                                       type: i < 32 ? .expense : .income, isActive: true, createdAt: nil))
        }

        var rng = SystemRandomNumberGenerator()
        let now = Date()
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"

        var txs: [AkifiIOS.Transaction] = []
        var i = 0
        while txs.count < txCount {
            i += 1
            let when = now.addingTimeInterval(-Double.random(in: 0...(210 * 86_400), using: &rng))
            let account = accounts[Int.random(in: 0..<accounts.count, using: &rng)]
            let roll = Int.random(in: 0..<100, using: &rng)
            let amount = Int64.random(in: 100_00...15_000_00, using: &rng)
            let raw = iso.string(from: when)
            let d = day.string(from: when)
            if roll < 12 {
                // Auto-transfer triplet into the shared account.
                let group = "g-\(i)"
                let src = accounts[1 + Int.random(in: 0..<personal.count, using: &rng)]
                let payer = Bool.random(using: &rng) ? me : partner
                txs.append(AkifiIOS.Transaction(id: "t-\(i)-e", userId: payer, accountId: shared.id, amount: amount,
                                       currency: "RUB", description: "Продукты", categoryId: "cat-\(i % 32)",
                                       type: .expense, date: d, rawDateTime: raw, merchantName: nil, merchantFuzzy: nil,
                                       transferGroupId: nil, paymentSourceAccountId: src.id, autoTransferGroupId: group,
                                       status: nil, createdAt: raw, updatedAt: nil))
                txs.append(AkifiIOS.Transaction(id: "t-\(i)-in", userId: payer, accountId: shared.id, amount: amount,
                                       currency: "RUB", description: nil, categoryId: nil, type: .income, date: d,
                                       rawDateTime: raw, merchantName: nil, merchantFuzzy: nil, transferGroupId: group,
                                       autoTransferGroupId: group, status: nil, createdAt: raw, updatedAt: nil))
                if payer == me {
                    txs.append(AkifiIOS.Transaction(id: "t-\(i)-out", userId: me, accountId: src.id, amount: amount,
                                           currency: src.currency.uppercased(), description: nil, categoryId: nil,
                                           type: .expense, date: d, rawDateTime: raw, merchantName: nil, merchantFuzzy: nil,
                                           transferGroupId: group, autoTransferGroupId: group, status: nil,
                                           createdAt: raw, updatedAt: nil))
                }
            } else {
                let isIncome = roll > 90
                txs.append(AkifiIOS.Transaction(id: "t-\(i)", userId: account.id == shared.id && Bool.random(using: &rng) ? partner : me,
                                       accountId: account.id, amount: amount, currency: account.currency.uppercased(),
                                       description: "Покупка \(i)", categoryId: "cat-\(isIncome ? 32 + i % 8 : i % 32)",
                                       type: isIncome ? .income : .expense, date: d, rawDateTime: raw,
                                       merchantName: "Магазин \(i % 60)", merchantFuzzy: nil, transferGroupId: nil,
                                       status: nil, createdAt: raw, updatedAt: nil))
            }
        }
        txs.sort { $0.rawDateTime > $1.rawDateTime }

        var budgets: [Budget] = []
        for b in 0..<8 {
            let limit = Int64(20_000_00) + Int64(b) * Int64(5_000_00)
            let period: BillingPeriod = b == 7 ? .weekly : .monthly
            let cats: [String] = ["cat-\(b)", "cat-\(b + 8)"]
            let ccy: String = b == 6 ? "USD" : "RUB"
            budgets.append(Budget(id: "b-\(b)", userId: me, budgetName: "Бюджет \(b)", amount: limit,
                                  billingPeriod: period, categoryIds: cats, currency: ccy))
        }
        var subs: [SubscriptionTracker] = []
        for s in 0..<12 {
            let price = Int64(299_00) + Int64(s) * Int64(100_00)
            let ccy: String = s % 3 == 0 ? "USD" : "RUB"
            let start: String = day.string(from: now.addingTimeInterval(-Double(s) * 20 * 86_400))
            let next: String = day.string(from: now.addingTimeInterval(Double(s) * 2 * 86_400))
            subs.append(SubscriptionTracker(id: "s-\(s)", userId: me, serviceName: "Сервис \(s)", amount: price,
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

    // MARK: - Harness

    /// Benchmarks take ~1 min and assert nothing, so they only run on demand:
    /// `TEST_RUNNER_AKIFI_BENCH=1 xcodebuild test … -only-testing:AkifiIOSTests/TabOpenBenchmarkTests`
    private func requireBenchmarkRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AKIFI_BENCH"] == "1",
                          "set TEST_RUNNER_AKIFI_BENCH=1 to run benchmarks")
    }

    private func report(_ name: String, _ samples: [Double]) {
        let s = samples.sorted()
        let median = s[s.count / 2]
        print(String(format: "BENCH|%@|%.1f|%.1f|%.1f", name, median, s.first!, s.last!))
    }

    private func time(_ block: () -> Void) -> Double {
        let t0 = CACurrentMediaTime()
        block()
        return (CACurrentMediaTime() - t0) * 1000
    }

    /// Hosts `view` in a phone-sized window and returns the window (kept alive
    /// by the caller) after the first synchronous layout pass.
    private func mount<V: View>(_ view: V, app: AppViewModel) -> (UIWindow, UIHostingController<AnyView>) {
        let host = UIHostingController(rootView: AnyView(view.environment(app).environment(CurrentAccountContext())))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private let tabs: [(String, () -> AnyView)] = [
        ("home", { AnyView(HomeTabView()) }),
        ("transactions", { AnyView(TransactionsTabView()) }),
        ("analytics", { AnyView(AnalyticsTabView()) }),
        ("budgets", { AnyView(BudgetsTabView()) }),
    ]

    // MARK: - Benchmarks

    /// First open of each tab: build + first layout, then the extra main-thread
    /// work its onAppear/.task state changes trigger in the next 300 ms.
    func test_bench_firstOpen_perTab() throws {
        try requireBenchmarkRun()
        for (name, make) in tabs {
            var build: [Double] = []
            var settle: [Double] = []
            for _ in 0..<5 {
                let app = Self.makeApp()
                var mounted: (UIWindow, UIHostingController<AnyView>)?
                build.append(time { mounted = mount(make(), app: app) })
                // Main-thread time spent re-laying-out after appear-driven state changes.
                let t0 = CACurrentMediaTime()
                var busy = 0.0
                while CACurrentMediaTime() - t0 < 0.3 {
                    busy += time {
                        mounted?.1.view.setNeedsLayout()
                        mounted?.1.view.layoutIfNeeded()
                    }
                    spin(0.01)
                }
                settle.append(busy)
                mounted?.0.isHidden = true
            }
            report("firstOpen.\(name).build", build)
            report("firstOpen.\(name).settle300ms", settle)
        }
    }

    /// The keep-alive cost: all four tabs visited (mounted), then ONE new
    /// transaction lands in DataStore (what happens after the user saves a
    /// transaction or a refresh completes). Measures the main-thread time to
    /// rebuild caches and re-render every live tab.
    func test_bench_oneTransactionChange_allVisitedTabs() throws {
        try requireBenchmarkRun()
        var samples: [Double] = []
        var cacheOnly: [Double] = []
        var perTab: [String: [Double]] = [:]
        for run in 0..<5 {
            let app = Self.makeApp()
            let windows = tabs.map { mount($0.1(), app: app) }
            spin(0.3)
            let store = app.dataStore
            let tx = AkifiIOS.Transaction(id: "new-\(run)", userId: Self.me, accountId: "acc-0", amount: 450_00,
                                 currency: "RUB", description: "Кофе", categoryId: "cat-1", type: .expense,
                                 date: "2026-11-16", rawDateTime: "2026-11-16T10:00:00", merchantName: nil,
                                 merchantFuzzy: nil, transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil)
            cacheOnly.append(time {
                store.transactions.insert(tx, at: 0)
                store.rebuildCaches()
            })
            var total = 0.0
            for (i, w) in windows.enumerated() {
                let ms = time { w.1.view.setNeedsLayout(); w.1.view.layoutIfNeeded() }
                perTab[tabs[i].0, default: []].append(ms)
                total += ms
            }
            samples.append(total)
            windows.forEach { $0.0.isHidden = true }
        }
        report("change.rebuildCaches", cacheOnly)
        report("change.rerender4Tabs", samples)
        for (name, _) in tabs { report("change.rerender.\(name)", perTab[name] ?? []) }
    }

    /// Where a tab's first-open time goes: each Home / Analytics panel
    /// mounted alone (fresh app per sample, so memos start cold).
    func test_bench_panelBreakdown() throws {
        try requireBenchmarkRun()
        let panels: [(String, () -> AnyView)] = [
            ("home.insights", { AnyView(InsightCardsView()) }),
            ("home.summary", { AnyView(HomeSummaryProbe()) }),
            ("home.recent", { AnyView(HomeRecentProbe()) }),
            ("home.recent.rowsOnly", { AnyView(RowsStackProbe()) }),
            ("home.recent.listOnly", { AnyView(EmptyListProbe()) }),
            ("home.carousel", { AnyView(HomeCarouselProbe()) }),
            ("home.streak", { AnyView(StreakBadgeView()) }),
            ("transactions.miniDashboard", { AnyView(MiniDashboardProbe()) }),
            ("analytics.forecast", { AnyView(ForecastProbe()) }),
            ("analytics.categories", { AnyView(CategoryProbe()) }),
            ("analytics.dailyLimit", { AnyView(DailyLimitWidgetView()) }),
        ]
        for (name, make) in panels {
            var build: [Double] = []
            for _ in 0..<5 {
                let app = Self.makeApp()
                var mounted: (UIWindow, UIHostingController<AnyView>)?
                build.append(time { mounted = mount(ScrollView { make() }, app: app) })
                mounted?.0.isHidden = true
            }
            report("panel.\(name)", build)
        }
    }

    /// Cold cost of each memoized derivation — what one data change costs
    /// per derivation now that nothing recomputes per read.
    func test_bench_derivations() throws {
        try requireBenchmarkRun()
        var samples: [String: [Double]] = [:]
        for _ in 0..<5 {
            let app = Self.makeApp()
            let store = app.dataStore
            let state = AnalyticsTabState(dataStore: store)
            samples["derive.forecast", default: []].append(time { _ = state.forecast(horizonMonths: 3) })
            samples["derive.categoryBreakdown", default: []].append(time { _ = state.categoryBreakdown(type: .expense) })
            samples["derive.cashflowPoints", default: []].append(time { _ = state.cashflowPoints })
            samples["derive.transactionIndex", default: []].append(time { _ = store.derivedCache.transactionIndex(for: store) })
            samples["derive.miniDashboard", default: []].append(time {
                _ = TransactionsMiniDashboardView.months(store.transactions) { store.amountInBase($0) }
            })
            let cm = app.currencyManager
            let ctx = store.currencyContext
            samples["derive.insights", default: []].append(time {
                _ = InsightEngine.generate(InsightEngine.Input(
                    transactions: store.transactions, categories: store.categories, budgets: store.budgets,
                    subscriptions: store.subscriptions,
                    formatAmount: { amount in MainActor.assumeIsolated { cm.formatAmount(amount.displayAmount) } },
                    accountsById: ctx.accountsById, fxRates: ctx.fxRates, baseCode: ctx.baseCode
                ))
            })
            samples["derive.memoHit.categoryBreakdown", default: []].append(time { _ = state.categoryBreakdown(type: .expense) })
        }
        for (name, s) in samples.sorted(by: { $0.key < $1.key }) { report(name, s) }
    }

    /// Scaling check: does the build cost grow linearly with history size?
    func test_bench_scaling_transactionsTab() throws {
        try requireBenchmarkRun()
        for n in [500, 1_300, 3_000] {
            var build: [Double] = []
            for _ in 0..<3 {
                let app = Self.makeApp(txCount: n)
                var mounted: (UIWindow, UIHostingController<AnyView>)?
                build.append(time { mounted = mount(TransactionsTabView(), app: app) })
                mounted?.0.isHidden = true
            }
            report("scaling.transactions.\(n)", build)
        }
    }
}

// MARK: - Panel probes (benchmark-only wrappers that read the environment)

private struct HomeSummaryProbe: View {
    @Environment(AppViewModel.self) private var app
    var body: some View { SummaryCardsView(transactions: app.dataStore.transactions, selectedAccount: nil) }
}

private struct HomeRecentProbe: View {
    @Environment(AppViewModel.self) private var app
    var body: some View {
        RecentTransactionsView(
            transactions: app.dataStore.derivedCache.recentTransactions(for: app.dataStore, accountId: nil),
            categories: app.dataStore.categories
        )
    }
}

private struct HomeCarouselProbe: View {
    @Environment(AppViewModel.self) private var app
    @State private var index = 0
    var body: some View {
        AccountCarouselView(accounts: app.dataStore.accounts, selectedIndex: $index, balanceFor: app.dataStore.balance)
    }
}

private struct MiniDashboardProbe: View {
    @Environment(AppViewModel.self) private var app
    var body: some View { TransactionsMiniDashboardView(transactions: app.dataStore.transactions) {} }
}

private struct ForecastProbe: View {
    @Environment(AppViewModel.self) private var app
    @State private var state = AnalyticsTabState()
    var body: some View { CashFlowForecastView(state: state.bind(app.dataStore)) }
}

private struct CategoryProbe: View {
    @Environment(AppViewModel.self) private var app
    @State private var state = AnalyticsTabState()
    var body: some View { CategoryBreakdownView(state: state.bind(app.dataStore)) }
}

private struct RowsStackProbe: View {
    @Environment(AppViewModel.self) private var app
    var body: some View {
        VStack {
            ForEach(app.dataStore.transactions.prefix(10)) { tx in
                TransactionRowView(transaction: tx, category: app.dataStore.category(for: tx))
            }
        }
    }
}

private struct EmptyListProbe: View {
    var body: some View {
        List { ForEach(0..<10, id: \.self) { Text("\($0)") } }
            .listStyle(.plain)
            .frame(height: 880)
    }
}
