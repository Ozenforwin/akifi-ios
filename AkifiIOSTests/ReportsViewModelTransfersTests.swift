import XCTest
@testable import AkifiIOS

/// `ReportsViewModel.transferBreakdown` — direction grouping for the
/// «Переводы» report segment — and the `.custom` period mode.
@MainActor
final class ReportsViewModelTransfersTests: XCTestCase {

    private lazy var store: DataStore = {
        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = ["USD": 1.0, "RUB": 100.0]
        store.currencyManager = cm
        store.accounts = [
            makeAccount(id: "acc-a", name: "Карта"),
            makeAccount(id: "acc-b", name: "Наличные")
        ]
        store.rebuildCaches()
        return store
    }()

    /// Fresh VM pinned to July 2026 — the month all fixtures use.
    private lazy var vm: ReportsViewModel = {
        let vm = ReportsViewModel()
        vm.periodMode = .month
        vm.selectedMonth = Self.date("2026-07-01")
        return vm
    }()

    private static func date(_ s: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    private func makeAccount(id: String, name: String) -> Account {
        Account(
            id: id, userId: "u1", name: name, icon: "💳", color: "#3B82F6",
            initialBalance: 100_000_00, currency: "RUB"
        )
    }

    private func makeLeg(
        id: String,
        accountId: String,
        type: TransactionType,
        amountNative: Int64 = 5_000_00,
        date: String = "2026-07-10",
        transferGroupId: String?
    ) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: accountId,
            amount: amountNative, amountNative: amountNative, currency: "RUB",
            description: nil, categoryId: nil, type: type,
            date: date, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: transferGroupId, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    // MARK: - Grouping

    func test_twoLegsOneGroup_collapseToOneDirection() {
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .expense, transferGroupId: "g1"),
            makeLeg(id: "t2", accountId: "acc-b", type: .income, transferGroupId: "g1")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].fromAccountId, "acc-a", "expense leg is the source")
        XCTAssertEqual(items[0].toAccountId, "acc-b")
        XCTAssertEqual(items[0].txCount, 1, "one OPERATION, not two legs")
        XCTAssertEqual(items[0].amount, 5_000_00)
        XCTAssertEqual(items[0].percentage, 100.0, accuracy: 0.01)
    }

    func test_sameDirectionTwice_merges() {
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .expense, amountNative: 1_000_00, transferGroupId: "g1"),
            makeLeg(id: "t2", accountId: "acc-b", type: .income, amountNative: 1_000_00, transferGroupId: "g1"),
            makeLeg(id: "t3", accountId: "acc-a", type: .expense, amountNative: 2_000_00, transferGroupId: "g2"),
            makeLeg(id: "t4", accountId: "acc-b", type: .income, amountNative: 2_000_00, transferGroupId: "g2")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].amount, 3_000_00)
        XCTAssertEqual(items[0].txCount, 2)
    }

    func test_oppositeDirections_staySeparate() {
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .expense, transferGroupId: "g1"),
            makeLeg(id: "t2", accountId: "acc-b", type: .income, transferGroupId: "g1"),
            makeLeg(id: "t3", accountId: "acc-b", type: .expense, transferGroupId: "g2"),
            makeLeg(id: "t4", accountId: "acc-a", type: .income, transferGroupId: "g2")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertEqual(items.count, 2, "A→B and B→A are distinct directions")
    }

    func test_missingPairLeg_becomesExternalDirection() {
        // Partner's account hidden by RLS — only the income leg is visible.
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .income, transferGroupId: "g1")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].fromAccountId, "unknown source = external")
        XCTAssertEqual(items[0].toAccountId, "acc-a")
    }

    func test_soloLegacyTransfer_negativeAmount_isOutgoing() {
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .transfer, amountNative: -3_000_00, transferGroupId: nil)
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].fromAccountId, "acc-a")
        XCTAssertNil(items[0].toAccountId)
        XCTAssertEqual(items[0].amount, 3_000_00, "amount reported as positive volume")
    }

    func test_nonTransferExpense_excluded() {
        let expense = makeLeg(id: "t1", accountId: "acc-a", type: .expense, transferGroupId: nil)

        let items = vm.transferBreakdown(from: [expense], dataStore: store)

        XCTAssertTrue(items.isEmpty, "plain expenses never appear in the transfers segment")
    }

    // MARK: - Account filter

    func test_accountFilter_matchesEitherLeg() {
        vm.selectedAccountId = "acc-b"
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .expense, transferGroupId: "g1"),
            makeLeg(id: "t2", accountId: "acc-b", type: .income, transferGroupId: "g1")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertEqual(items.count, 1, "direction passes when EITHER endpoint is the selected account")
    }

    func test_accountFilter_dropsUnrelatedDirections() {
        vm.selectedAccountId = "acc-c"
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .expense, transferGroupId: "g1"),
            makeLeg(id: "t2", accountId: "acc-b", type: .income, transferGroupId: "g1")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Period filter

    func test_periodFilter_excludesOtherMonths() {
        let txs = [
            makeLeg(id: "t1", accountId: "acc-a", type: .expense, date: "2026-06-15", transferGroupId: "g1"),
            makeLeg(id: "t2", accountId: "acc-b", type: .income, date: "2026-06-15", transferGroupId: "g1")
        ]

        let items = vm.transferBreakdown(from: txs, dataStore: store)

        XCTAssertTrue(items.isEmpty, "June transfer must not appear in the July report")
    }

    // MARK: - Custom period mode

    func test_customPeriod_inclusiveBoundaries() {
        vm.setCustomRange(start: Self.date("2026-07-10"), end: Self.date("2026-07-20"))

        XCTAssertTrue(vm.isInSelectedPeriod(Self.date("2026-07-10")), "start boundary inclusive")
        XCTAssertTrue(vm.isInSelectedPeriod(Self.date("2026-07-20")), "end boundary inclusive")
        XCTAssertFalse(vm.isInSelectedPeriod(Self.date("2026-07-09")))
        XCTAssertFalse(vm.isInSelectedPeriod(Self.date("2026-07-21")))
    }

    func test_setCustomRange_swapsReversedBounds() {
        vm.setCustomRange(start: Self.date("2026-07-20"), end: Self.date("2026-07-10"))

        XCTAssertEqual(vm.customStart, Calendar.current.startOfDay(for: Self.date("2026-07-10")))
        XCTAssertEqual(vm.customEnd, Calendar.current.startOfDay(for: Self.date("2026-07-20")))
        XCTAssertEqual(vm.periodMode, .custom)
    }

    func test_customMode_pagerIsNoOp() {
        vm.setCustomRange(start: Self.date("2026-07-01"), end: Self.date("2026-07-15"))
        let savedStart = vm.customStart
        let savedMonth = vm.selectedMonth

        vm.nextPeriod()
        vm.previousPeriod()

        XCTAssertEqual(vm.customStart, savedStart)
        XCTAssertEqual(vm.selectedMonth, savedMonth, "prev/next must not move anything in custom mode")
        XCTAssertNil(vm.nextPeriodDate())
    }

    func test_previousCustomRange_sameLengthWindow() {
        vm.setCustomRange(start: Self.date("2026-07-11"), end: Self.date("2026-07-20"))

        let prev = vm.previousCustomRange()

        XCTAssertEqual(prev.end, Calendar.current.startOfDay(for: Self.date("2026-07-10")))
        XCTAssertEqual(prev.start, Calendar.current.startOfDay(for: Self.date("2026-07-01")), "10-day window shifts back by its own length")
    }

    func test_monthMode_regression_stillFiltersByMonth() {
        vm.periodMode = .month
        vm.selectedMonth = Self.date("2026-07-01")

        XCTAssertTrue(vm.isInSelectedPeriod(Self.date("2026-07-31")))
        XCTAssertFalse(vm.isInSelectedPeriod(Self.date("2026-08-01")))
    }
}
