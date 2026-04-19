import XCTest
@testable import AkifiIOS

final class SkillTreeEngineTests: XCTestCase {

    private func emptyInput() -> SkillTreeEngine.Input {
        SkillTreeEngine.Input(
            transactions: [], accounts: [], categories: [],
            budgets: [], subscriptions: [], goals: [],
            currentStreak: 0, hasExportedReport: false
        )
    }

    private func tx(type: TransactionType = .expense, date: String = "2026-04-15") -> Transaction {
        Transaction(
            id: UUID().uuidString, userId: "u1", accountId: "a1",
            amount: 100_00, currency: "RUB", description: nil,
            categoryId: nil, type: type, date: date,
            merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func account(id: String = "a1") -> Account {
        Account(id: id, userId: "u1", name: "Main", icon: "💳",
                color: "#60A5FA", initialBalance: 0, isPrimary: true, currency: "RUB")
    }

    private func category(id: String = "c1") -> AkifiIOS.Category {
        AkifiIOS.Category(id: id, userId: "u1", accountId: nil, name: "Food",
                 icon: "🍔", color: "#60A5FA", type: .expense,
                 isActive: true, createdAt: nil)
    }

    func testEmptyInput_NoNodesUnlocked() {
        let unlocked = SkillTreeEngine.unlockedNodes(emptyInput())
        XCTAssertTrue(unlocked.isEmpty)
    }

    func testFirstTransaction_UnlocksFirstTransactionNode() {
        var input = emptyInput()
        input = SkillTreeEngine.Input(
            transactions: [tx()], accounts: input.accounts,
            categories: input.categories, budgets: input.budgets,
            subscriptions: input.subscriptions, goals: input.goals,
            currentStreak: 0, hasExportedReport: false
        )
        XCTAssertTrue(SkillTreeEngine.unlockedNodes(input).contains(.firstTransaction))
    }

    func testPrerequisiteChain_BudgetRequiresTransaction() {
        // Have an active budget but no transactions → firstBudget shouldn't unlock
        // (its prerequisite `firstTransaction` not satisfied).
        let budget = Budget(id: "b1", userId: "u1", amount: 10_000_00,
                            billingPeriod: .monthly, isActive: true)
        let input = SkillTreeEngine.Input(
            transactions: [], accounts: [], categories: [],
            budgets: [budget], subscriptions: [], goals: [],
            currentStreak: 0, hasExportedReport: false
        )
        XCTAssertFalse(SkillTreeEngine.unlockedNodes(input).contains(.firstBudget))

        // Now add a transaction — both should unlock.
        let input2 = SkillTreeEngine.Input(
            transactions: [tx()], accounts: [account()], categories: [],
            budgets: [budget], subscriptions: [], goals: [],
            currentStreak: 0, hasExportedReport: false
        )
        let unlocked = SkillTreeEngine.unlockedNodes(input2)
        XCTAssertTrue(unlocked.contains(.firstTransaction))
        XCTAssertTrue(unlocked.contains(.firstBudget))
    }

    func testStreakNodes_Cascade() {
        // streak30 requires streak7. streak100 requires streak30.
        let txs = [tx()]
        let input = SkillTreeEngine.Input(
            transactions: txs, accounts: [], categories: [],
            budgets: [], subscriptions: [], goals: [],
            currentStreak: 100, hasExportedReport: false
        )
        let unlocked = SkillTreeEngine.unlockedNodes(input)
        XCTAssertTrue(unlocked.contains(.streak7))
        XCTAssertTrue(unlocked.contains(.streak30))
        XCTAssertTrue(unlocked.contains(.streak100))
    }

    func testExpertReporter_RequiresExportFlag() {
        let input = SkillTreeEngine.Input(
            transactions: [tx()], accounts: [account()], categories: [category()],
            budgets: [], subscriptions: [], goals: [],
            currentStreak: 0, hasExportedReport: false
        )
        XCTAssertFalse(SkillTreeEngine.unlockedNodes(input).contains(.expertReporter))

        let input2 = SkillTreeEngine.Input(
            transactions: [tx()], accounts: [account()], categories: [category()],
            budgets: [], subscriptions: [], goals: [],
            currentStreak: 0, hasExportedReport: true
        )
        XCTAssertTrue(SkillTreeEngine.unlockedNodes(input2).contains(.expertReporter))
    }
}
