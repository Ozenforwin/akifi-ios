import XCTest
@testable import AkifiIOS

/// Contract §B2: who may set `personal_debt_user_id`, on which rows; and
/// the local reminder planner (§A6).
final class PersonalDebtRulesTests: XCTestCase {

    let shared = Account(id: "s", userId: "aaaa", name: "Семейный", icon: "👪", color: "#000", initialBalance: 0, currency: "rub")
    lazy var members = [
        AccountMember(id: "m1", accountId: "s", userId: "aaaa", role: .owner),
        AccountMember(id: "m2", accountId: "s", userId: "bbbb", role: .editor),
        AccountMember(id: "m3", accountId: "s", userId: "cccc", role: .viewer),
    ]

    func test_markableRows() {
        XCTAssertTrue(PersonalDebtRules.isMarkableExpense(type: .expense, transferGroupId: nil), "direct / main auto-transfer expense")
        XCTAssertFalse(PersonalDebtRules.isMarkableExpense(type: .expense, transferGroupId: "g"), "a transfer leg")
        XCTAssertFalse(PersonalDebtRules.isMarkableExpense(type: .income, transferGroupId: nil), "plain income")
    }

    func test_sharedNeedsTwoPartiesAndMoney() {
        XCTAssertTrue(PersonalDebtRules.isShared(account: shared, partyCount: 2))
        XCTAssertFalse(PersonalDebtRules.isShared(account: shared, partyCount: 1))
        let debt = Account(id: "d", userId: "aaaa", name: "Маша", icon: "👤", color: "#000", initialBalance: 0, accountType: .debt)
        XCTAssertFalse(PersonalDebtRules.isShared(account: debt, partyCount: 2), "never a debt account")
    }

    func test_roles() {
        XCTAssertEqual(PersonalDebtRules.role(of: "AAAA", account: shared, members: members), .owner)
        XCTAssertEqual(PersonalDebtRules.role(of: "bbbb", account: shared, members: members), .editor)
        XCTAssertEqual(PersonalDebtRules.role(of: "cccc", account: shared, members: members), .viewer)
        XCTAssertNil(PersonalDebtRules.role(of: "zzzz", account: shared, members: members))
        XCTAssertTrue(PersonalDebtRules.canMarkOthers(myRole: .owner))
        XCTAssertTrue(PersonalDebtRules.canMarkOthers(myRole: .editor))
        XCTAssertFalse(PersonalDebtRules.canMarkOthers(myRole: .viewer))
        XCTAssertFalse(PersonalDebtRules.canMarkOthers(myRole: nil))
    }

    /// Owner/editor pick anyone (me first); otherwise only me.
    func test_selectableParties() {
        let editor = PersonalDebtRules.selectableParties(me: "bbbb", myRole: .editor, account: shared, members: members)
        XCTAssertEqual(editor.map(\.userId), ["bbbb", "aaaa", "cccc"])
        let viewer = PersonalDebtRules.selectableParties(me: "cccc", myRole: .viewer, account: shared, members: members)
        XCTAssertEqual(viewer.map(\.userId), ["cccc"])
    }

    func test_resolvedMark() {
        let parties = PersonalDebtRules.selectableParties(me: "aaaa", myRole: .owner, account: shared, members: members)
        XCTAssertNil(PersonalDebtRules.resolvedMark(enabled: false, chosen: "bbbb", me: "aaaa", selectable: parties))
        XCTAssertEqual(PersonalDebtRules.resolvedMark(enabled: true, chosen: nil, me: "aaaa", selectable: parties), "aaaa", "defaults to me")
        XCTAssertEqual(PersonalDebtRules.resolvedMark(enabled: true, chosen: "BBBB", me: "aaaa", selectable: parties), "bbbb")
        XCTAssertEqual(PersonalDebtRules.resolvedMark(enabled: true, chosen: "zzzz", me: "aaaa", selectable: parties), "aaaa", "not a party → me")
    }

    func test_updatesMarkOnlyWhenChanged() {
        XCTAssertFalse(PersonalDebtRules.updatesMark(old: nil, new: nil))
        XCTAssertFalse(PersonalDebtRules.updatesMark(old: "AAAA", new: "aaaa"))
        XCTAssertTrue(PersonalDebtRules.updatesMark(old: "aaaa", new: nil))
        XCTAssertTrue(PersonalDebtRules.updatesMark(old: nil, new: "aaaa"))
    }
}

final class DebtReminderPlannerTests: XCTestCase {

    private func entry(_ id: String, due: String?, remind: Bool = true, balance: Int64 = 100, closed: Bool = false) -> DebtEntry {
        DebtEntry(accountId: id, name: id, icon: nil, color: nil, currency: "RUB", balance: balance, contact: nil,
                  dueDate: due, remind: remind, note: nil, closedAt: closed ? "x" : nil, hasDetails: true, isOverdue: false, createdAt: nil)
    }

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 12))! }

    func test_plan() {
        let plan = DebtReminderPlanner.plan([
            entry("ok", due: "2026-12-31"),
            entry("noRemind", due: "2026-12-31", remind: false),
            entry("settled", due: "2026-12-31", balance: 0),
            entry("closed", due: "2026-12-31", closed: true),
            entry("past", due: "2026-11-27"),
            entry("todayPassed", due: "2026-11-28"),
            entry("noDue", due: nil),
        ], notificationsEnabled: true, now: now, calendar: calendar)
        XCTAssertEqual(plan.map(\.accountId), ["ok"])
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: plan[0].fireDate)
        XCTAssertEqual(comps, DateComponents(year: 2026, month: 12, day: 31, hour: 10))
    }

    func test_respectsNotificationSettings() {
        XCTAssertTrue(DebtReminderPlanner.plan([entry("ok", due: "2026-12-31")], notificationsEnabled: false, now: now, calendar: calendar).isEmpty)
    }

    func test_cancelsStaleOnly() {
        let plan = DebtReminderPlanner.plan([entry("ok", due: "2026-12-31")], notificationsEnabled: true, now: now, calendar: calendar)
        let pending = [DebtReminderPlanner.identifier(accountId: "ok"), DebtReminderPlanner.identifier(accountId: "gone"), "subscription-reminder-1"]
        XCTAssertEqual(DebtReminderPlanner.toCancel(pendingIdentifiers: pending, plan: plan), [DebtReminderPlanner.identifier(accountId: "gone")])
    }
}
