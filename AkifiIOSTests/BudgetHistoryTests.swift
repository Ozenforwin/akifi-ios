import XCTest
@testable import AkifiIOS

/// `BudgetMath.matchingTransactions` — the rows behind a budget card, shown
/// when the card is tapped. The list and `spentAmount` must always describe
/// the same set, so they are asserted against each other here.
final class BudgetHistoryTests: XCTestCase {

    private let ctx: BudgetMath.CurrencyContext = ([:], [:], "RUB")

    private let period = (
        start: date("2026-08-01"),
        end: date("2026-08-31")
    )

    private func makeBudget(categoryIds: [String]? = nil, accountIds: [String]? = nil) -> Budget {
        Budget(
            id: "b1", userId: "u1", accountIds: accountIds,
            amount: 10_000_00, billingPeriod: .monthly, categoryIds: categoryIds
        )
    }

    private func makeTx(
        id: String,
        amount: Int64 = 1_000_00,
        categoryId: String? = "cat-food",
        accountId: String? = "acc-1",
        type: TransactionType = .expense,
        date: String = "2026-08-10",
        transferGroupId: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: accountId,
            amount: amount, amountNative: amount, currency: "RUB",
            description: nil, categoryId: categoryId, type: type,
            date: date, merchantName: nil, merchantFuzzy: nil,
            transferGroupId: transferGroupId, status: nil, createdAt: nil, updatedAt: nil
        )
    }

    // MARK: - Filtering

    func test_matchingTransactions_keepsOnlyBudgetCategories() {
        let budget = makeBudget(categoryIds: ["cat-food"])
        let txs = [
            makeTx(id: "in-budget", categoryId: "cat-food"),
            makeTx(id: "other-category", categoryId: "cat-taxi")
        ]

        let rows = BudgetMath.matchingTransactions(budget: budget, transactions: txs, period: period)

        XCTAssertEqual(rows.map(\.id), ["in-budget"])
    }

    func test_matchingTransactions_dropsIncomeAndTransfers() {
        let budget = makeBudget()
        let txs = [
            makeTx(id: "expense"),
            makeTx(id: "income", type: .income),
            makeTx(id: "transfer-leg", transferGroupId: "g1")
        ]

        let rows = BudgetMath.matchingTransactions(budget: budget, transactions: txs, period: period)

        XCTAssertEqual(rows.map(\.id), ["expense"])
    }

    func test_matchingTransactions_respectsLinkedAccounts() {
        let budget = makeBudget(accountIds: ["acc-1", "acc-2"])
        let txs = [
            makeTx(id: "on-acc-1", accountId: "acc-1"),
            makeTx(id: "on-acc-2", accountId: "acc-2"),
            makeTx(id: "elsewhere", accountId: "acc-9")
        ]

        let rows = BudgetMath.matchingTransactions(budget: budget, transactions: txs, period: period)

        XCTAssertEqual(Set(rows.map(\.id)), ["on-acc-1", "on-acc-2"])
    }

    func test_matchingTransactions_staysInsidePeriod() {
        let budget = makeBudget()
        let txs = [
            makeTx(id: "before", date: "2026-07-31"),
            makeTx(id: "first-day", date: "2026-08-01"),
            makeTx(id: "last-day", date: "2026-08-31"),
            makeTx(id: "after", date: "2026-09-01")
        ]

        let rows = BudgetMath.matchingTransactions(budget: budget, transactions: txs, period: period)

        XCTAssertEqual(Set(rows.map(\.id)), ["first-day", "last-day"], "period bounds are inclusive")
    }

    func test_matchingTransactions_newestFirst() {
        let budget = makeBudget()
        let txs = [
            makeTx(id: "older", date: "2026-08-03"),
            makeTx(id: "newest", date: "2026-08-20"),
            makeTx(id: "middle", date: "2026-08-11")
        ]

        let rows = BudgetMath.matchingTransactions(budget: budget, transactions: txs, period: period)

        XCTAssertEqual(rows.map(\.id), ["newest", "middle", "older"])
    }

    // MARK: - Agreement with the card

    /// The number on the card is the sum of the rows in the sheet — if these
    /// two ever drift apart, the history looks like it is lying.
    func test_matchingTransactions_sumEqualsSpentAmount() {
        let budget = makeBudget(categoryIds: ["cat-food"], accountIds: ["acc-1"])
        let txs = [
            makeTx(id: "a", amount: 1_200_00),
            makeTx(id: "b", amount: 340_50),
            makeTx(id: "ignored-category", categoryId: "cat-taxi"),
            makeTx(id: "ignored-account", accountId: "acc-9"),
            makeTx(id: "ignored-period", date: "2026-07-01"),
            makeTx(id: "ignored-income", type: .income)
        ]

        let rows = BudgetMath.matchingTransactions(
            budget: budget, transactions: txs, period: period
        )
        let listed = rows.reduce(Int64(0)) { $0 + $1.amountNative }
        let spent = BudgetMath.spentAmount(
            budget: budget, transactions: txs, period: period, currencyContext: ctx
        )

        XCTAssertEqual(listed, spent)
        XCTAssertEqual(spent, 1_540_50)
    }
}

private func date(_ s: String) -> Date {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    return df.date(from: s)!
}
