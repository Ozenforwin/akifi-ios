import Foundation

/// Client mirror of the server rules for `transactions.personal_debt_user_id`
/// (trigger `trg_transactions_personal_debt`, contract §B2). The server is
/// the authority; the UI uses this to offer only what it would accept.
enum PersonalDebtRules {

    /// A party of a shared account as the expense form offers it.
    struct Party: Identifiable, Equatable, Sendable {
        let userId: String
        let role: AccountRole
        var id: String { userId }
    }

    /// The row shape the mark is allowed on from the expense form: an
    /// expense outside any transfer (a direct expense, or the main expense of
    /// a «Оплачено с» triplet).
    static func isMarkableExpense(type: TransactionType, transferGroupId: String?) -> Bool {
        type == .expense && transferGroupId == nil
    }

    /// Shared = two or more parties (owner + members), never a debt account.
    static func isShared(account: Account, partyCount: Int) -> Bool {
        account.isMoneyAccount && partyCount >= 2
    }

    /// Owners and editors of the account may mark any party; everyone else
    /// only themselves (`personal_debt_forbidden` otherwise).
    static func canMarkOthers(myRole: AccountRole?) -> Bool {
        myRole == .owner || myRole == .editor
    }

    /// My role on `account`: owner when I own it, else my member row's role.
    static func role(of userId: String?, account: Account, members: [AccountMember]) -> AccountRole? {
        guard let userId else { return nil }
        if account.userId.lowercased() == userId.lowercased() { return .owner }
        return members.first { $0.userId.lowercased() == userId.lowercased() }?.role
    }

    /// Who may be picked: everyone (owner first) for an owner/editor, only
    /// me otherwise. Viewers can't write rows at all (RLS).
    static func selectableParties(me: String, myRole: AccountRole?, account: Account, members: [AccountMember]) -> [Party] {
        var parties: [Party] = []
        var seen: Set<String> = []
        func add(_ id: String, _ role: AccountRole) {
            let key = id.lowercased()
            guard seen.insert(key).inserted else { return }
            parties.append(Party(userId: key, role: role))
        }
        add(account.userId, .owner)
        for m in members { add(m.userId, m.role) }
        guard canMarkOthers(myRole: myRole) else {
            return parties.filter { $0.userId == me.lowercased() }
        }
        // Me first, then the rest in a stable order.
        return parties.sorted { a, b in
            if (a.userId == me.lowercased()) != (b.userId == me.lowercased()) { return a.userId == me.lowercased() }
            if a.role != b.role { return a.role == .owner }
            return a.userId < b.userId
        }
    }

    /// The value the form writes: nil when the toggle is off, else the
    /// chosen party — falling back to me when the choice is not allowed.
    static func resolvedMark(enabled: Bool, chosen: String?, me: String, selectable: [Party]) -> String? {
        guard enabled else { return nil }
        if let chosen, selectable.contains(where: { $0.userId == chosen.lowercased() }) { return chosen.lowercased() }
        return me.lowercased()
    }

    /// Whether an edit must send the column: only when it changed.
    static func updatesMark(old: String?, new: String?) -> Bool {
        old?.lowercased() != new?.lowercased()
    }
}

/// Local reminders on a debt's due date (contract §A6). Pure planner; the
/// side effects live in `DebtReminderScheduler`.
enum DebtReminderPlanner {

    static let identifierPrefix = "debt-reminder-"

    static func identifier(accountId: String) -> String { identifierPrefix + accountId.lowercased() }

    struct Reminder: Equatable, Sendable {
        let accountId: String
        let name: String
        let currency: String
        let balance: Int64
        /// Fire moment: 10:00 local on the due date.
        let fireDate: Date
    }

    /// `remind && open && balance ≠ 0 && due date in the future` → one
    /// reminder at 10:00 local time on that day. Nothing at all while the
    /// user switched notifications off (`notificationsEnabled`).
    static func plan(
        _ entries: [DebtEntry],
        notificationsEnabled: Bool,
        now: Date = Date(),
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> [Reminder] {
        guard notificationsEnabled else { return [] }
        return entries.compactMap { entry in
            guard entry.remind, entry.isOpen, entry.balance != 0,
                  let due = entry.dueDate,
                  let day = AppDateFormatters.day(due, calendar: calendar),
                  let fire = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day),
                  fire > now else { return nil }
            return Reminder(accountId: entry.accountId, name: entry.name, currency: entry.currency, balance: entry.balance, fireDate: fire)
        }
    }

    /// Identifiers to cancel: every pending debt reminder that is not in
    /// the plan any more.
    static func toCancel(pendingIdentifiers: [String], plan: [Reminder]) -> [String] {
        let keep = Set(plan.map { identifier(accountId: $0.accountId) })
        return pendingIdentifiers.filter { $0.hasPrefix(identifierPrefix) && !keep.contains($0) }
    }
}
