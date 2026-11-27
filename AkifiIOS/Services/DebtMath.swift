import Foundation

/// One debt as the «Долги» screens show it: the server summary's details
/// merged with the debt account's balance.
struct DebtEntry: Identifiable, Equatable, Sendable {
    let accountId: String
    /// Person's name (`counterparty_name`, the account name without details).
    let name: String
    let icon: String?
    let color: String?
    /// Upper-case ISO code of the debt account.
    let currency: String
    /// Minor units of `currency`. > 0 they owe me, < 0 I owe them.
    let balance: Int64
    let contact: String?
    /// "yyyy-MM-dd".
    let dueDate: String?
    let remind: Bool
    let note: String?
    let closedAt: String?
    let hasDetails: Bool
    let isOverdue: Bool
    let createdAt: String?

    var id: String { accountId }
    var isClosed: Bool { closedAt != nil }
    var direction: DebtDirection { DebtDirection(balance: balance) }
    var isOpen: Bool { !isClosed }
}

/// Pure «Долги» math — contract §A1/§A4. No UI, no network.
enum DebtMath {

    /// Balance of a debt account in its own currency (minor units):
    /// `initial_balance + Σ income − Σ expense` of `amountNative` — the
    /// server's `debts_summary.balance` formula and the contract's offline
    /// fallback. All rows of a debt account belong to its owner, so the
    /// local set is complete (ADR-003).
    static func balance(of account: Account, transactions: [Transaction]) -> Int64 {
        NativeBalance.balance(of: account, transactions: transactions)
    }

    /// `is_overdue`: open, balance ≠ 0 and `due_date < today` ("yyyy-MM-dd",
    /// lexicographic order is date order).
    static func isOverdue(dueDate: String?, balance: Int64, isClosed: Bool, today: String) -> Bool {
        guard !isClosed, balance != 0, let due = dueDate, !due.isEmpty else { return false }
        return String(due.prefix(10)) < today
    }

    /// Today in the user's local calendar, "yyyy-MM-dd".
    static func localToday(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        AppDateFormatters.localDate(in: timeZone).string(from: now)
    }

    /// Merges the server summary with the local debt accounts.
    ///
    /// - Existence: the union of both — a debt created on another device is
    ///   shown from the summary before the next accounts refresh, a debt
    ///   created a moment ago from the local account before the summary is
    ///   refetched.
    /// - Balance: the server's when `preferServerBalance` (the summary is
    ///   newer than every local write), otherwise the local one, which
    ///   already contains this device's own (also queued) movements.
    /// - Details (due date, closed, note…): the summary's; a local-only
    ///   account reads as "no details yet".
    /// - `today` for the overdue flag: the server's when it sent one
    ///   (profile time zone), else the device's.
    static func merge(
        summary: DebtsSummary?,
        debtAccounts: [Account],
        transactions: [Transaction],
        preferServerBalance: Bool,
        today: String
    ) -> [DebtEntry] {
        let serverById = Dictionary((summary?.debts ?? []).map { ($0.accountId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let localById = Dictionary(debtAccounts.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let effectiveToday = summary?.today ?? today

        var ids: [String] = []
        var seen: Set<String> = []
        for key in Array(localById.keys) + Array(serverById.keys) where seen.insert(key).inserted {
            ids.append(key)
        }

        var out: [DebtEntry] = []
        for key in ids {
            let server = serverById[key]
            let local = localById[key]
            let localBalance = local.map { balance(of: $0, transactions: transactions) }
            let bal: Int64
            if let server, preferServerBalance || localBalance == nil {
                bal = server.balance
            } else {
                bal = localBalance ?? server?.balance ?? 0
            }
            let closedAt = server?.closedAt
            let dueDate = server?.dueDate
            out.append(DebtEntry(
                accountId: local?.id ?? server?.accountId ?? key,
                name: server?.counterpartyName ?? local?.name ?? "",
                icon: server?.icon ?? local?.icon,
                color: server?.color ?? local?.color,
                currency: (local?.currency ?? server?.currency ?? "RUB").uppercased(),
                balance: bal,
                contact: server?.counterpartyContact,
                dueDate: dueDate,
                remind: server?.remind ?? false,
                note: server?.note,
                closedAt: closedAt,
                hasDetails: server?.hasDetails ?? false,
                isOverdue: isOverdue(dueDate: dueDate, balance: bal, isClosed: closedAt != nil, today: effectiveToday),
                createdAt: server?.createdAt ?? local?.createdAt
            ))
        }
        return sorted(out)
    }

    /// Contract order: open first, then `due_date` (nulls last),
    /// `created_at`, `account_id`.
    static func sorted(_ entries: [DebtEntry]) -> [DebtEntry] {
        entries.sorted { a, b in
            if a.isClosed != b.isClosed { return !a.isClosed }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            let ca = a.createdAt ?? "", cb = b.createdAt ?? ""
            if ca != cb { return ca < cb }
            return a.accountId < b.accountId
        }
    }

    /// Open debts only, one entry per currency, no FX (`debts_summary.totals`).
    static func totals(_ entries: [DebtEntry]) -> [DebtsSummary.Total] {
        var byCurrency: [String: (owed: Int64, owe: Int64, n: Int)] = [:]
        for entry in entries where entry.isOpen {
            var t = byCurrency[entry.currency, default: (0, 0, 0)]
            if entry.balance > 0 { t.owed += entry.balance }
            if entry.balance < 0 { t.owe += -entry.balance }
            t.n += 1
            byCurrency[entry.currency] = t
        }
        return byCurrency.keys.sorted().map { code in
            let t = byCurrency[code]!
            return DebtsSummary.Total(currency: code, owedToMe: t.owed, iOwe: t.owe, openCount: t.n)
        }
    }

    /// Totals converted into one currency (USD-pivot `rates`, the
    /// `CurrencyManager.rates` convention). A missing rate leaves that
    /// currency out and reports it, so a sum is never silently 1:1.
    static func convertedTotals(
        _ totals: [DebtsSummary.Total],
        to target: String,
        rates: [String: Double]
    ) -> (owedToMe: Int64, iOwe: Int64, missing: [String]) {
        let dst = target.uppercased()
        var owed: Int64 = 0, owe: Int64 = 0
        var missing: [String] = []
        for t in totals {
            let src = t.currency.uppercased()
            if src == dst {
                owed += t.owedToMe; owe += t.iOwe
                continue
            }
            guard let from = rates[src], from > 0, let to = rates[dst], to > 0 else {
                missing.append(src)
                continue
            }
            owed += convert(t.owedToMe, from: from, to: to)
            owe += convert(t.iOwe, from: from, to: to)
        }
        return (owed, owe, missing)
    }

    private static func convert(_ minor: Int64, from: Double, to: Double) -> Int64 {
        MoneyRounding.kopecks(Decimal(minor) / 100 / Decimal(from) * Decimal(to))
    }

    /// Open debts as signed balances for the net-worth calculator: > 0 is an
    /// asset («мне должны»), < 0 a liability («я должен»). A closed debt
    /// left the totals (contract §A6), so it is not here.
    static func netWorthBalances(_ entries: [DebtEntry]) -> [(currency: String, amount: Int64)] {
        entries.filter { $0.isOpen && $0.balance != 0 }.map { ($0.currency, $0.balance) }
    }

    /// The legs of a debt account, newest first — the person's history.
    static func movements(accountId: String, transactions: [Transaction]) -> [Transaction] {
        transactions
            .filter { $0.accountId == accountId }
            .sorted { a, b in
                if a.rawDateTime != b.rawDateTime { return a.rawDateTime > b.rawDateTime }
                return (a.createdAt ?? "") > (b.createdAt ?? "")
            }
    }

    /// Signed effect of one row on the debt balance (+ they owe me more).
    static func signedEffect(_ tx: Transaction) -> Int64 {
        NativeBalance.signedAmount(tx)
    }
}
