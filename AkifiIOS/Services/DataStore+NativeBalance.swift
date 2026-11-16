import Foundation

/// Account balance in the ACCOUNT's own currency (ADR-001), as opposed to
/// `DataStore.balance(for:)`, which since aab6c52 returns the balance
/// FX-normalised into the user's base currency for the carousel / net-worth
/// UI.
///
/// Anything that shows or edits a single account's balance *as a number in
/// that account's currency* — the account form, an assistant context that
/// labels the value with `account.currency` — must use this. Feeding
/// `balance(for:)` there treated a base-currency figure as account currency:
/// opening a $640 USD account and just renaming it wrote
/// `initial_balance ≈ 59 200 − net`, i.e. a $59 200 balance (M1).
///
/// Sign convention is exactly the one `DataStore.rebuildCaches()` uses, so
/// `nativeBalance` converted to base equals `balance(for:)` (± FX rounding):
/// income adds, expense subtracts, a legacy `.transfer` row carries its own
/// sign. Transfer legs (`transferGroupId`) are ordinary income/expense rows
/// and count like any other — they move money in or out of THIS account.
enum NativeBalance {

    /// Signed effect of one row on its account's balance, kopecks of the
    /// account currency.
    static func signedAmount(_ tx: Transaction) -> Int64 {
        switch tx.type {
        case .income: return tx.amountNative
        case .expense: return -tx.amountNative
        case .transfer: return tx.amountNative
        }
    }

    /// Σ signed `amountNative` over the account's rows.
    static func net(accountId: String, transactions: [Transaction]) -> Int64 {
        var net: Int64 = 0
        for tx in transactions where tx.accountId == accountId {
            net += signedAmount(tx)
        }
        return net
    }

    /// `initial_balance + net`, kopecks of `account.currency`. No FX.
    static func balance(of account: Account, transactions: [Transaction]) -> Int64 {
        account.initialBalance + net(accountId: account.id, transactions: transactions)
    }

    /// The `initial_balance` (kopecks) that makes the account show
    /// `desiredBalance`, given its rows. `accounts.initial_balance` is a
    /// bigint of WHOLE units, so the result is rounded half away from zero
    /// to a multiple of 100 — the repository would otherwise truncate it,
    /// shifting the balance by up to a whole unit on every save.
    static func initialBalance(forDesiredBalance desiredBalance: Int64, net: Int64) -> Int64 {
        let raw = desiredBalance - net
        let wholeUnits = MoneyRounding.rounded(Decimal(raw) / 100, scale: 0)
        return Int64(truncating: wholeUnits as NSDecimalNumber) * 100
    }
}

extension DataStore {

    /// Balance of `account` in its OWN currency (kopecks). O(transactions);
    /// meant for forms and single-account screens, not per-row rendering.
    func nativeBalance(for account: Account) -> Int64 {
        NativeBalance.balance(of: account, transactions: transactions)
    }

    /// Σ signed `amountNative` of the account's rows (its own currency).
    func nativeNet(for account: Account) -> Int64 {
        NativeBalance.net(accountId: account.id, transactions: transactions)
    }

    /// Income / expense of `account` for the calendar month containing
    /// `now`, in BASE currency kopecks — the carousel's month chips.
    ///
    /// Reads the per-account monthly buckets `rebuildCaches()` already
    /// builds (transfers and auto-transfer legs excluded, so moving money
    /// between own accounts is not "income"). Month keys come from
    /// `tx.date`, which holds the user's local wall-clock day, so "now" is
    /// bucketed with the local calendar too.
    func currentMonthFlow(for account: Account, now: Date = Date(), calendar: Calendar = .current) -> MonthlyAggregate {
        // `monthlyAggregatesByAccount` is @ObservationIgnored. Touch the
        // observed inputs it is derived from so a SwiftUI body calling this
        // re-renders when rows or FX change (every `rebuildCaches()` follows
        // a `transactions` write and reassigns `accountIncome`).
        _ = transactions.isEmpty
        _ = accountIncome.isEmpty
        let key = Self.monthKey(for: now, calendar: calendar)
        return monthlyAggregatesByAccount[account.id]?[key]
            ?? MonthlyAggregate(monthKey: key, income: 0, expense: 0)
    }

    /// "yyyy-MM" of `date` in `calendar`'s time zone, Gregorian digits
    /// regardless of the device calendar (Buddhist/Japanese would otherwise
    /// produce "2569-11").
    nonisolated static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let comps = gregorian.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    /// The main expense row of the auto-transfer triplet `leg` belongs to,
    /// when this device can see it. `nil` for non-legs and when RLS hides it.
    func mainExpense(forAutoTransferLeg leg: Transaction) -> Transaction? {
        Self.mainExpense(forAutoTransferLeg: leg, in: transactions)
    }

    nonisolated static func mainExpense(forAutoTransferLeg leg: Transaction, in transactions: [Transaction]) -> Transaction? {
        guard leg.isAutoTransferLeg, let group = leg.autoTransferGroupId else { return nil }
        return transactions.first {
            $0.autoTransferGroupId == group && $0.transferGroupId == nil && $0.type == .expense
        }
    }
}
