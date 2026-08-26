import XCTest
@testable import AkifiIOS

/// Regression cover for the «Отчёт → Доходы → категория» drill-down.
///
/// Fixtures mirror real June-2026 rows: an income «Подарок Оли» and an
/// expense «Цветы» whose categories share the display name «Подарки» but
/// differ in id AND type. The breakdown groups by name, so the detail
/// sheet must re-apply the type filter or the expense shows up in the
/// Income list rendered green with a "+".
@MainActor
final class ReportsCategoryDrilldownTests: XCTestCase {

    private lazy var store: DataStore = {
        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        // USD-pivot: 1 USD = 83.7 RUB — the rate behind the 11.46 $ → 959 ₽
        // row on the user's screenshot.
        cm.rates = ["USD": 1.0, "RUB": 83.7]
        store.currencyManager = cm
        store.accounts = [
            Account(
                id: "acc-rub", userId: "u1", name: "IBT BANK", icon: "💳",
                color: "#3B82F6", initialBalance: 0, currency: "RUB"
            ),
            Account(
                id: "acc-usd", userId: "u1", name: "ByBit", icon: "🟡",
                color: "#F59E0B", initialBalance: 0, currency: "USD"
            )
        ]
        store.rebuildCaches()
        return store
    }()

    private lazy var vm: ReportsViewModel = {
        let vm = ReportsViewModel()
        vm.periodMode = .month
        vm.selectedMonth = Self.date("2026-06-01")
        return vm
    }()

    private static func date(_ s: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    /// Same display name, different id, opposite types — exactly the shape
    /// that made the two paths disagree.
    private let categories = [
        Category(
            id: "cat-gift-in", userId: "u1", accountId: nil, name: "Подарки",
            icon: "🎁", color: "#22C55E", type: .income, isActive: true, createdAt: nil
        ),
        Category(
            id: "cat-gift-out", userId: "u1", accountId: nil, name: "Подарки",
            icon: "🎁", color: "#EF4444", type: .expense, isActive: true, createdAt: nil
        )
    ]

    /// 5 595,55 ₽ received on 8 June.
    private let giftIncome = Transaction(
        id: "tx-gift-in", userId: "u1", accountId: "acc-rub",
        amount: 5_595_55, amountNative: 5_595_55, currency: "RUB",
        description: "Подарок Оли", categoryId: "cat-gift-in", type: .income,
        date: "2026-06-08", merchantName: nil, merchantFuzzy: nil,
        transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
    )

    /// 11,46 $ spent on 16 June — ≈959 ₽ once FX-normalized.
    private let flowersExpense = Transaction(
        id: "tx-flowers", userId: "u1", accountId: "acc-usd",
        amount: 11_46, amountNative: 11_46, currency: "USD",
        description: "Цветы", categoryId: "cat-gift-out", type: .expense,
        date: "2026-06-16", merchantName: nil, merchantFuzzy: nil,
        transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
    )

    private var transactions: [Transaction] { [giftIncome, flowersExpense] }

    // MARK: - The bug

    func test_incomeDrilldown_excludesSameNamedExpense() {
        vm.selectedSegment = .income

        let rows = vm.transactions(
            inCategoryNamed: "Подарки", from: transactions, categories: categories
        )

        XCTAssertEqual(rows.map(\.id), ["tx-gift-in"],
                       "«Цветы» is an expense — it must not appear in the Income drill-down")
    }

    func test_expenseDrilldown_excludesSameNamedIncome() {
        vm.selectedSegment = .expense

        let rows = vm.transactions(
            inCategoryNamed: "Подарки", from: transactions, categories: categories
        )

        XCTAssertEqual(rows.map(\.id), ["tx-flowers"])
    }

    /// The header ("1 операций / 5 596 ₽") and the list below it are built
    /// by two different code paths — this pins them together.
    func test_drilldownRowCount_matchesBreakdownTxCount() {
        for segment in [ReportsViewModel.ReportSegment.income, .expense] {
            vm.selectedSegment = segment

            let items = vm.categoryBreakdown(
                from: transactions, categories: categories, dataStore: store
            )
            guard let gifts = items.first(where: { $0.category.name == "Подарки" }) else {
                XCTFail("breakdown has no «Подарки» slice on \(segment)")
                continue
            }

            let rows = vm.transactions(
                inCategoryNamed: "Подарки", from: transactions, categories: categories
            )

            XCTAssertEqual(gifts.txCount, rows.count,
                           "header count and list length diverged on \(segment)")
        }
    }

    /// Transfers carry a category too, but they belong to neither segment.
    func test_drilldown_skipsTransferLegs() {
        vm.selectedSegment = .income
        let leg = Transaction(
            id: "tx-leg", userId: "u1", accountId: "acc-rub",
            amount: 1_000_00, amountNative: 1_000_00, currency: "RUB",
            description: "Перевод", categoryId: "cat-gift-in", type: .income,
            date: "2026-06-10", merchantName: nil, merchantFuzzy: nil,
            transferGroupId: "grp-1", status: nil, createdAt: nil, updatedAt: nil
        )

        let rows = vm.transactions(
            inCategoryNamed: "Подарки", from: transactions + [leg], categories: categories
        )

        XCTAssertEqual(rows.map(\.id), ["tx-gift-in"])
    }

    /// Rows outside the selected month stay out regardless of type.
    func test_drilldown_respectsSelectedPeriod() {
        vm.selectedSegment = .income
        vm.selectedMonth = Self.date("2026-07-01")

        let rows = vm.transactions(
            inCategoryNamed: "Подарки", from: transactions, categories: categories
        )

        XCTAssertTrue(rows.isEmpty)
    }
}
