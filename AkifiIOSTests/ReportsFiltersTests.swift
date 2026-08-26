import XCTest
@testable import AkifiIOS

/// Report filters: the account/category exclusion sets and the pager's
/// back edge (which used to walk into empty 2025 and strand the user).
@MainActor
final class ReportsFiltersTests: XCTestCase {

    private lazy var vm: ReportsViewModel = {
        let vm = ReportsViewModel()
        vm.periodMode = .month
        vm.selectedMonth = Self.date("2026-08-01")
        return vm
    }()

    private static func date(_ s: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    private func makeTx(
        id: String,
        accountId: String? = "acc-1",
        categoryId: String? = "cat-food",
        date: String = "2026-08-10"
    ) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: accountId,
            amount: 1_000_00, amountNative: 1_000_00, currency: "RUB",
            description: nil, categoryId: categoryId, type: .expense,
            date: date, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: nil, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    // MARK: - Account exclusions

    func test_noExclusions_keepEveryAccount() {
        let txs = [makeTx(id: "a", accountId: "acc-1"), makeTx(id: "b", accountId: "acc-2")]

        XCTAssertEqual(Set(vm.monthTransactions(from: txs).map(\.id)), ["a", "b"])
    }

    func test_excludedAccount_isFilteredOut() {
        vm.excludedAccountIds = ["acc-2"]
        let txs = [makeTx(id: "a", accountId: "acc-1"), makeTx(id: "b", accountId: "acc-2")]

        XCTAssertEqual(vm.monthTransactions(from: txs).map(\.id), ["a"])
    }

    /// "All accounts except one" is the whole point of an exclusion set:
    /// an account added later stays visible without touching the filter.
    func test_excludedAccount_newAccountRemainsIncluded() {
        vm.excludedAccountIds = ["acc-2"]
        let txs = [makeTx(id: "brand-new", accountId: "acc-99")]

        XCTAssertEqual(vm.monthTransactions(from: txs).map(\.id), ["brand-new"])
    }

    func test_rowsWithoutAccount_areNeverExcluded() {
        vm.excludedAccountIds = ["acc-1"]
        let txs = [makeTx(id: "orphan", accountId: nil)]

        XCTAssertEqual(vm.monthTransactions(from: txs).map(\.id), ["orphan"])
    }

    // MARK: - Category exclusions

    func test_excludedCategory_isFilteredOut() {
        vm.excludedCategoryIds = ["cat-taxi"]
        let txs = [makeTx(id: "food", categoryId: "cat-food"), makeTx(id: "taxi", categoryId: "cat-taxi")]

        XCTAssertEqual(vm.monthTransactions(from: txs).map(\.id), ["food"])
    }

    /// Uncategorized rows are filtered through a sentinel id so the
    /// "Без категории" bucket behaves like every other row.
    func test_uncategorizedBucket_canBeExcluded() {
        vm.excludedCategoryIds = [ReportsViewModel.uncategorizedId]
        let txs = [makeTx(id: "none", categoryId: nil), makeTx(id: "food", categoryId: "cat-food")]

        XCTAssertEqual(vm.monthTransactions(from: txs).map(\.id), ["food"])
    }

    func test_accountAndCategoryExclusions_combine() {
        vm.excludedAccountIds = ["acc-2"]
        vm.excludedCategoryIds = ["cat-taxi"]
        let txs = [
            makeTx(id: "keep", accountId: "acc-1", categoryId: "cat-food"),
            makeTx(id: "wrong-account", accountId: "acc-2", categoryId: "cat-food"),
            makeTx(id: "wrong-category", accountId: "acc-1", categoryId: "cat-taxi")
        ]

        XCTAssertEqual(vm.monthTransactions(from: txs).map(\.id), ["keep"])
    }

    // MARK: - Pager back edge

    func test_canGoPrevious_withoutDataBoundary_isUnrestricted() {
        vm.earliestDataDate = nil

        XCTAssertTrue(vm.canGoPrevious)
    }

    func test_canGoPrevious_stopsAtTheMonthOfTheOldestTransaction() {
        vm.earliestDataDate = Self.date("2026-07-15")

        vm.selectedMonth = Self.date("2026-08-01")
        XCTAssertTrue(vm.canGoPrevious, "July holds the oldest row — stepping back is allowed")

        vm.selectedMonth = Self.date("2026-07-01")
        XCTAssertFalse(vm.canGoPrevious, "June is empty — the pager must stop here")
    }

    func test_previousPeriod_doesNotMoveBeyondTheBoundary() {
        vm.earliestDataDate = Self.date("2026-07-15")
        vm.selectedMonth = Self.date("2026-07-01")

        vm.previousPeriod()

        XCTAssertEqual(vm.selectedMonth, Self.date("2026-07-01"), "stayed put instead of landing in empty 2025")
    }

    func test_canGoPrevious_yearMode_allowsTheYearHoldingTheOldestRow() {
        vm.periodMode = .year
        vm.earliestDataDate = Self.date("2025-03-01")

        vm.selectedMonth = Self.date("2026-08-01")
        XCTAssertTrue(vm.canGoPrevious)

        vm.selectedMonth = Self.date("2025-08-01")
        XCTAssertFalse(vm.canGoPrevious)
    }

    func test_canGoPrevious_quarterMode_stopsAfterTheOldestQuarter() {
        vm.periodMode = .quarter
        vm.earliestDataDate = Self.date("2026-05-20")   // Q2

        vm.selectedMonth = Self.date("2026-08-01")      // Q3 → back into Q2
        XCTAssertTrue(vm.canGoPrevious)

        vm.selectedMonth = Self.date("2026-05-01")      // Q2 → back into empty Q1
        XCTAssertFalse(vm.canGoPrevious)
    }
}
