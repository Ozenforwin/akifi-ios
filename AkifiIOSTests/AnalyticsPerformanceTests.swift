import XCTest
@testable import AkifiIOS

/// Reproduces the per-body-eval cost of the Analytics tab on synthetic
/// data so we can quantify the proposed optimizations before doing them.
///
/// Run with:
///   xcodebuild test -scheme AkifiIOS \
///     -only-testing:AkifiIOSTests/AnalyticsPerformanceTests
///
/// `measure {}` reports the average wall-clock per iteration in Xcode's
/// test report. Each test prints a one-line summary too so the numbers
/// are visible in CI logs without opening the .xcresult.
final class AnalyticsPerformanceTests: XCTestCase {

    // MARK: - Fixture sizes

    private let txCount = 1_000
    private let accountCount = 5

    // MARK: - Synthetic data

    private lazy var accounts: [Account] = (0..<accountCount).map { i in
        let ccy = ["RUB", "USD", "EUR", "VND", "IDR"][i % 5]
        return Account(
            id: "acc-\(i)",
            userId: "u1",
            name: "Account \(i)",
            icon: "💰",
            color: "#3B82F6",
            initialBalance: 10_000_00,
            currency: ccy
        )
    }

    private lazy var accountsById: [String: Account] = Dictionary(
        uniqueKeysWithValues: accounts.map { ($0.id, $0) }
    )

    private let fxRates: [String: Decimal] = [
        "USD": 1,
        "RUB": 92.5,
        "EUR": Decimal(string: "0.92")!,
        "VND": 25_400,
        "IDR": 16_300
    ]

    /// Rates as `[String: Double]` — mimics what `CurrencyManager.rates`
    /// actually stores. The production `DataStore.amountInBase` re-maps
    /// these to Decimal on every call; we keep the same shape so the
    /// per-call rebuild cost is honest.
    private lazy var fxRatesAsDouble: [String: Double] = fxRates.mapValues {
        Double(truncating: $0 as NSDecimalNumber)
    }

    private let baseCode = "RUB"

    private lazy var categories: [Category] = (0..<20).map { i in
        Category(
            id: "cat-\(i)",
            userId: "u1",
            accountId: nil,
            name: "Category \(i)",
            icon: "🛒",
            color: "#94A3B8",
            type: .expense,
            isActive: true,
            createdAt: nil
        )
    }

    private lazy var transactions: [Transaction] = (0..<txCount).map { i in
        let acc = accounts[i % accountCount]
        let cat = categories[i % categories.count]
        let monthOffset = -(i % 12)             // spread over last 12 months
        let day = (i % 28) + 1
        let date = isoDate(monthOffset: monthOffset, day: day)
        let isExpense = (i % 3) != 0            // 2/3 expenses, 1/3 income
        let isTransfer = (i % 17) == 0          // sprinkle a few transfers

        return Transaction(
            id: "tx-\(i)",
            userId: "u1",
            accountId: acc.id,
            amount: Int64(((i % 50) + 1) * 100_00),
            amountNative: Int64(((i % 50) + 1) * 100_00),
            currency: acc.currency,
            description: "tx \(i)",
            categoryId: cat.id,
            type: isTransfer ? .transfer : (isExpense ? .expense : .income),
            date: date,
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: isTransfer ? "g-\(i)" : nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private static let isoDF: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private func isoDate(monthOffset: Int, day: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let monthStart = cal.date(byAdding: .month, value: monthOffset, to: now)!
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = day
        return Self.isoDF.string(from: cal.date(from: comps)!)
    }

    // MARK: - Tests

    /// Lower bound: pure FX-normalize, with the lookup dicts built once
    /// outside the loop. This is what we *would* pay if the DataStore
    /// cached `currencyContext` (or precomputed amountInBase per tx).
    func test_baseline_fxNormalize_with_cached_context() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5

        var sum: Int64 = 0
        measure(options: opts) {
            sum = 0
            for tx in transactions {
                sum &+= TransactionMath.amountInBase(
                    tx,
                    accountsById: accountsById,
                    fxRates: fxRates,
                    baseCode: baseCode
                )
            }
        }
        print("[bench] baseline cached-context sum = \(sum)")
    }

    /// Production behavior: rebuild `accountsById` and remap `fxRates`
    /// to Decimal on every single tx (mirrors DataStore.amountInBase).
    func test_current_dataStore_pattern_rebuild_per_call() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        let accs = accounts
        let ratesD = fxRatesAsDouble
        let txs = transactions

        var sum: Int64 = 0
        measure(options: opts) {
            sum = 0
            for tx in txs {
                // Verbatim copy of DataStore.amountInBase(_:):
                let bc = baseCode.uppercased()
                let rates: [String: Decimal] = ratesD.mapValues { Decimal($0) }
                let byId = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
                sum &+= TransactionMath.amountInBase(
                    tx, accountsById: byId, fxRates: rates, baseCode: bc
                )
            }
        }
        print("[bench] current per-call rebuild sum = \(sum)")
    }

    /// Reproduces `MonthlySummaryView.monthTotals(offset:)` × 2 (current
    /// + previous month). Uses the production rebuild-per-call pattern.
    func test_monthlySummary_two_passes_current_pattern() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        let cal = Calendar.current
        let txs = transactions
        let accs = accounts
        let ratesD = fxRatesAsDouble

        measure(options: opts) {
            for offset in [0, -1] {
                let target = cal.date(byAdding: .month, value: offset, to: Date())!
                let comps = cal.dateComponents([.year, .month], from: target)
                var income: Decimal = 0
                var expense: Decimal = 0
                for tx in txs {
                    guard !tx.isTransfer else { continue }
                    guard let date = Self.isoDF.date(from: tx.date) else { continue }
                    let txComps = cal.dateComponents([.year, .month], from: date)
                    guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                    // amountInBaseDisplay (current pattern):
                    let bc = baseCode.uppercased()
                    let rates: [String: Decimal] = ratesD.mapValues { Decimal($0) }
                    let byId = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
                    let kop = TransactionMath.amountInBase(
                        tx, accountsById: byId, fxRates: rates, baseCode: bc
                    )
                    let amount = Decimal(kop) / 100
                    if tx.type == .income { income += amount }
                    else if tx.type == .expense { expense += amount }
                }
                _ = (income, expense)
            }
        }
    }

    /// Reproduces `CashflowTrendView.trendData` — 6 month buckets, full
    /// pass per bucket, current rebuild-per-call pattern.
    func test_cashflowTrend_6_month_passes_current_pattern() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        let cal = Calendar.current
        let txs = transactions
        let accs = accounts
        let ratesD = fxRatesAsDouble

        measure(options: opts) {
            for offset in stride(from: -5, through: 0, by: 1) {
                let monthDate = cal.date(byAdding: .month, value: offset, to: Date())!
                let comps = cal.dateComponents([.year, .month], from: monthDate)
                var income: Decimal = 0
                var expense: Decimal = 0
                for tx in txs {
                    guard !tx.isTransfer else { continue }
                    guard let date = Self.isoDF.date(from: tx.date) else { continue }
                    let txComps = cal.dateComponents([.year, .month], from: date)
                    guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                    let bc = baseCode.uppercased()
                    let rates: [String: Decimal] = ratesD.mapValues { Decimal($0) }
                    let byId = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
                    let kop = TransactionMath.amountInBase(
                        tx, accountsById: byId, fxRates: rates, baseCode: bc
                    )
                    let amount = Decimal(kop) / 100
                    if tx.type == .income { income += amount }
                    else if tx.type == .expense { expense += amount }
                }
                _ = (income, expense)
            }
        }
    }

    /// Reproduces `CategoryBreakdownView.data` — total reduce + per-cat
    /// dict (= 2 full passes) + linear category lookup. Current pattern.
    func test_categoryBreakdown_current_pattern() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        let txs = transactions
        let accs = accounts
        let ratesD = fxRatesAsDouble
        let cats = categories

        measure(options: opts) {
            let expenses = txs.filter { $0.type == .expense && !$0.isTransfer }
            // total
            let total = expenses.reduce(Decimal(0)) { acc, tx in
                let bc = baseCode.uppercased()
                let rates: [String: Decimal] = ratesD.mapValues { Decimal($0) }
                let byId = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
                let kop = TransactionMath.amountInBase(
                    tx, accountsById: byId, fxRates: rates, baseCode: bc
                )
                return acc + Decimal(kop) / 100
            }
            // by-category
            var byCategory: [String: Decimal] = [:]
            for tx in expenses {
                let catId = tx.categoryId ?? "uncategorized"
                let bc = baseCode.uppercased()
                let rates: [String: Decimal] = ratesD.mapValues { Decimal($0) }
                let byId = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
                let kop = TransactionMath.amountInBase(
                    tx, accountsById: byId, fxRates: rates, baseCode: bc
                )
                byCategory[catId, default: 0] += Decimal(kop) / 100
            }
            // Linear category lookup (categories.first { $0.id == catId })
            var rendered: [(String, Decimal, Double)] = []
            for (catId, amount) in byCategory {
                let cat = cats.first { $0.id == catId }
                let pct = total > 0
                    ? Double(truncating: (amount / total * 100) as NSDecimalNumber)
                    : 0
                rendered.append((cat?.name ?? "?", amount, pct))
            }
            _ = rendered
        }
    }

    /// Optimized variant — proves that the proposed fixes actually help.
    /// Pre-computes `amountInBase` once per tx + caches parsed dates.
    /// This is the lower-bound for what a fixed Analytics tab would cost
    /// per body-eval (steps 1, 2 from the recommendations).
    func test_optimized_full_analytics_render() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        let cal = Calendar.current
        let txs = transactions

        // Pre-pass (would live in DataStore.recomputeCaches, runs once
        // after every loadAll, NOT per body-eval):
        var amountInBaseCache: [String: Int64] = [:]
        var dateCache: [String: Date] = [:]
        amountInBaseCache.reserveCapacity(txs.count)
        dateCache.reserveCapacity(txs.count)
        for tx in txs {
            amountInBaseCache[tx.id] = TransactionMath.amountInBase(
                tx, accountsById: accountsById, fxRates: fxRates, baseCode: baseCode
            )
            if let d = Self.isoDF.date(from: tx.date) { dateCache[tx.id] = d }
        }

        measure(options: opts) {
            // 1. MonthlySummary × 2
            for offset in [0, -1] {
                let target = cal.date(byAdding: .month, value: offset, to: Date())!
                let comps = cal.dateComponents([.year, .month], from: target)
                var income: Int64 = 0, expense: Int64 = 0
                for tx in txs {
                    guard !tx.isTransfer else { continue }
                    guard let date = dateCache[tx.id] else { continue }
                    let txComps = cal.dateComponents([.year, .month], from: date)
                    guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                    let kop = amountInBaseCache[tx.id] ?? 0
                    if tx.type == .income { income &+= kop }
                    else if tx.type == .expense { expense &+= kop }
                }
                _ = (income, expense)
            }
            // 2. CashflowTrend × 6
            for offset in stride(from: -5, through: 0, by: 1) {
                let monthDate = cal.date(byAdding: .month, value: offset, to: Date())!
                let comps = cal.dateComponents([.year, .month], from: monthDate)
                var income: Int64 = 0, expense: Int64 = 0
                for tx in txs {
                    guard !tx.isTransfer else { continue }
                    guard let date = dateCache[tx.id] else { continue }
                    let txComps = cal.dateComponents([.year, .month], from: date)
                    guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                    let kop = amountInBaseCache[tx.id] ?? 0
                    if tx.type == .income { income &+= kop }
                    else if tx.type == .expense { expense &+= kop }
                }
                _ = (income, expense)
            }
            // 3. CategoryBreakdown — single pass
            var total: Int64 = 0
            var byCategory: [String: Int64] = [:]
            for tx in txs where tx.type == .expense && !tx.isTransfer {
                let kop = amountInBaseCache[tx.id] ?? 0
                total &+= kop
                let catId = tx.categoryId ?? "uncategorized"
                byCategory[catId, default: 0] &+= kop
            }
            _ = (total, byCategory)
        }
    }

    /// Same total work as `test_optimized_full_analytics_render` but with
    /// the *current* (rebuild-per-call) pattern. Shows the apples-to-
    /// apples speedup of caches alone for one full Analytics render.
    func test_current_full_analytics_render() {
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        let cal = Calendar.current
        let txs = transactions
        let accs = accounts
        let ratesD = fxRatesAsDouble
        let cats = categories

        func amountInBaseDisplay(_ tx: Transaction) -> Decimal {
            let bc = baseCode.uppercased()
            let rates: [String: Decimal] = ratesD.mapValues { Decimal($0) }
            let byId = Dictionary(uniqueKeysWithValues: accs.map { ($0.id, $0) })
            let kop = TransactionMath.amountInBase(
                tx, accountsById: byId, fxRates: rates, baseCode: bc
            )
            return Decimal(kop) / 100
        }

        measure(options: opts) {
            // 1. MonthlySummary × 2
            for offset in [0, -1] {
                let target = cal.date(byAdding: .month, value: offset, to: Date())!
                let comps = cal.dateComponents([.year, .month], from: target)
                var income: Decimal = 0, expense: Decimal = 0
                for tx in txs {
                    guard !tx.isTransfer else { continue }
                    guard let date = Self.isoDF.date(from: tx.date) else { continue }
                    let txComps = cal.dateComponents([.year, .month], from: date)
                    guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                    let amt = amountInBaseDisplay(tx)
                    if tx.type == .income { income += amt }
                    else if tx.type == .expense { expense += amt }
                }
                _ = (income, expense)
            }
            // 2. CashflowTrend × 6
            for offset in stride(from: -5, through: 0, by: 1) {
                let monthDate = cal.date(byAdding: .month, value: offset, to: Date())!
                let comps = cal.dateComponents([.year, .month], from: monthDate)
                var income: Decimal = 0, expense: Decimal = 0
                for tx in txs {
                    guard !tx.isTransfer else { continue }
                    guard let date = Self.isoDF.date(from: tx.date) else { continue }
                    let txComps = cal.dateComponents([.year, .month], from: date)
                    guard txComps.year == comps.year, txComps.month == comps.month else { continue }
                    let amt = amountInBaseDisplay(tx)
                    if tx.type == .income { income += amt }
                    else if tx.type == .expense { expense += amt }
                }
                _ = (income, expense)
            }
            // 3. CategoryBreakdown — 2 passes + linear cat lookup
            let expenses = txs.filter { $0.type == .expense && !$0.isTransfer }
            let total = expenses.reduce(Decimal(0)) { $0 + amountInBaseDisplay($1) }
            var byCategory: [String: Decimal] = [:]
            for tx in expenses {
                let catId = tx.categoryId ?? "uncategorized"
                byCategory[catId, default: 0] += amountInBaseDisplay(tx)
            }
            for (catId, _) in byCategory {
                _ = cats.first { $0.id == catId }
            }
            _ = total
        }
    }
}
