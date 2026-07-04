import Foundation

@Observable @MainActor
final class ReportsViewModel {

    // MARK: - State

    var selectedMonth: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }()
    var selectedSegment: ReportSegment = .expense
    var selectedAccountId: String?
    var periodMode: PeriodMode = .month

    /// Custom period bounds (used when `periodMode == .custom`).
    /// Defaults: current month start … today.
    var customStart: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }()
    var customEnd: Date = Calendar.current.startOfDay(for: Date())

    /// What the report shows. Transfers are a separate world from the
    /// category breakdown (no categories — directions between accounts),
    /// hence a dedicated enum instead of overloading `CategoryType`.
    enum ReportSegment: CaseIterable {
        case expense, income, transfers
    }

    /// Bridge for the category-breakdown internals (and the detail sheet),
    /// which only distinguish expense vs income. Never read on the
    /// transfers segment.
    var selectedType: CategoryType { selectedSegment == .income ? .income : .expense }

    enum PeriodMode: CaseIterable {
        case month, quarter, year, custom

        var label: String {
            switch self {
            case .month: String(localized: "filter.month")
            case .quarter: String(localized: "report.quarter")
            case .year: String(localized: "report.year")
            case .custom: String(localized: "report.period.custom")
            }
        }
    }

    /// Applies a user-picked custom range: normalizes to start-of-day and
    /// swaps the bounds if they were entered backwards.
    func setCustomRange(start: Date, end: Date) {
        let cal = Calendar.current
        let s = cal.startOfDay(for: start)
        let e = cal.startOfDay(for: end)
        customStart = min(s, e)
        customEnd = max(s, e)
        periodMode = .custom
    }

    // MARK: - Period Navigation

    func nextPeriod() {
        guard let step = periodStep else { return }
        let cal = Calendar.current
        if let next = cal.date(byAdding: step.component, value: step.value, to: selectedMonth),
           next <= Date() {
            selectedMonth = next
        }
    }

    func previousPeriod() {
        guard let step = periodStep else { return }
        let cal = Calendar.current
        if let prev = cal.date(byAdding: step.component, value: -step.value, to: selectedMonth) {
            selectedMonth = prev
        }
    }

    /// nil for `.custom` — a free-form range has no natural pager step.
    private var periodStep: (component: Calendar.Component, value: Int)? {
        switch periodMode {
        case .month: (.month, 1)
        case .quarter: (.month, 3)
        case .year: (.year, 1)
        case .custom: nil
        }
    }

    /// Same-length window ending the day before `customStart` — the
    /// "previous period" for PDF comparison when the mode is `.custom`.
    func previousCustomRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: customStart, to: customEnd).day ?? 0
        let prevEnd = cal.date(byAdding: .day, value: -1, to: customStart)!
        let prevStart = cal.date(byAdding: .day, value: -days, to: prevEnd)!
        return (prevStart, prevEnd)
    }

    // Keep old names for backward compat
    func nextMonth() { nextPeriod() }
    func previousMonth() { previousPeriod() }

    // MARK: - Period Labels

    func periodLabel(_ date: Date) -> String {
        switch periodMode {
        case .month:
            return Self.monthLabelFormatter.string(from: date).capitalizedFirstLetter
        case .quarter:
            let cal = Calendar.current
            let month = cal.component(.month, from: date)
            let quarter = (month - 1) / 3 + 1
            let year = cal.component(.year, from: date)
            return "Q\(quarter) \(year)"
        case .year:
            let cal = Calendar.current
            let year = cal.component(.year, from: date)
            return "\(year)"
        case .custom:
            // The passed date is ignored — the label always describes the
            // stored custom range.
            let cal = Calendar.current
            let sameYear = cal.component(.year, from: customStart) == cal.component(.year, from: customEnd)
            let startFmt = sameYear ? Self.rangeDayFormatter : Self.rangeDayYearFormatter
            return "\(startFmt.string(from: customStart)) – \(Self.rangeDayYearFormatter.string(from: customEnd))"
        }
    }

    func prevPeriodDate() -> Date {
        guard let step = periodStep else { return customStart }
        let cal = Calendar.current
        return cal.date(byAdding: step.component, value: -step.value, to: selectedMonth)!
    }

    func nextPeriodDate() -> Date? {
        guard let step = periodStep else { return nil }
        let cal = Calendar.current
        let next = cal.date(byAdding: step.component, value: step.value, to: selectedMonth)
        guard let next, next <= Date() else { return nil }
        return next
    }

    // MARK: - Private formatters

    private static let txDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "LLLL yyyy"
        return df
    }()

    private static let shortMonthLabelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "LLL yyyy"
        return df
    }()

    private static let rangeDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.setLocalizedDateFormatFromTemplate("d MMM")
        return df
    }()

    private static let rangeDayYearFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return df
    }()

    // MARK: - Filtered transactions (respects periodMode)

    func monthTransactions(from all: [Transaction]) -> [Transaction] {
        all.filter { tx in
            if let accountId = selectedAccountId, tx.accountId != accountId { return false }
            guard let txDate = Self.txDateFormatter.date(from: tx.date) else { return false }
            return isInSelectedPeriod(txDate)
        }
    }

    /// The pure period predicate, shared by the category path (which also
    /// filters by account) and the transfers path (which must NOT pre-filter
    /// by account — a direction matches when EITHER leg touches the account).
    func isInSelectedPeriod(_ txDate: Date) -> Bool {
        let calendar = Calendar.current
        switch periodMode {
        case .month:
            let sel = calendar.dateComponents([.year, .month], from: selectedMonth)
            let txC = calendar.dateComponents([.year, .month], from: txDate)
            return txC.year == sel.year && txC.month == sel.month

        case .quarter:
            let selYear = calendar.component(.year, from: selectedMonth)
            let selMonth = calendar.component(.month, from: selectedMonth)
            let selQuarter = (selMonth - 1) / 3
            let txYear = calendar.component(.year, from: txDate)
            let txMonth = calendar.component(.month, from: txDate)
            let txQuarter = (txMonth - 1) / 3
            return txYear == selYear && txQuarter == selQuarter

        case .year:
            let selYear = calendar.component(.year, from: selectedMonth)
            let txYear = calendar.component(.year, from: txDate)
            return txYear == selYear

        case .custom:
            // tx dates parse to midnight; bounds are start-of-day → both
            // boundaries are inclusive.
            return txDate >= customStart && txDate <= customEnd
        }
    }

    // MARK: - Computed: totals

    // ADR-001: totals are summed across accounts that may be in different
    // currencies, so each amount_native must be FX-normalized into the
    // user's base currency before aggregation. Using `tx.amount` directly
    // let VND/USD rows appear at nominal value.
    func monthIncome(from transactions: [Transaction], dataStore: DataStore) -> Int64 {
        transactions
            .filter { $0.type == .income && !$0.isTransfer }
            .reduce(Int64(0)) { $0 + dataStore.amountInBase($1) }
    }

    func monthExpense(from transactions: [Transaction], dataStore: DataStore) -> Int64 {
        transactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .reduce(Int64(0)) { $0 + dataStore.amountInBase($1) }
    }

    func monthCashflow(from transactions: [Transaction], dataStore: DataStore) -> Int64 {
        monthIncome(from: transactions, dataStore: dataStore)
            - monthExpense(from: transactions, dataStore: dataStore)
    }

    // MARK: - Computed: category breakdown

    struct CategoryBreakdownItem: Identifiable, Sendable {
        var id: String { category.id }
        let category: Category
        let amount: Int64
        let percentage: Double
        let txCount: Int
    }

    func categoryBreakdown(
        from transactions: [Transaction],
        categories: [Category],
        dataStore: DataStore
    ) -> [CategoryBreakdownItem] {
        let monthTxs = monthTransactions(from: transactions)
        let filtered = monthTxs.filter { tx in
            !tx.isTransfer && (
                (selectedType == .expense && tx.type == .expense) ||
                (selectedType == .income && tx.type == .income)
            )
        }

        let total = filtered.reduce(Int64(0)) { $0 + dataStore.amountInBase($1) }
        guard total > 0 else { return [] }

        let categoryIndex = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let fallbackCategory = Category(
            id: "uncategorized",
            userId: "",
            accountId: nil,
            name: String(localized: "transaction.noCategory"),
            icon: "💰",
            color: "#94A3B8",
            type: selectedType,
            isActive: true,
            createdAt: nil
        )

        // Group by display name (not ID) to merge same-name categories
        // from shared accounts (e.g. both users have "Кофе" with different IDs).
        var byNameAmount: [String: Int64] = [:]
        var byNameCount: [String: Int] = [:]
        var byNameCategory: [String: Category] = [:]

        for tx in filtered {
            let cat = tx.categoryId.flatMap { categoryIndex[$0] } ?? fallbackCategory
            let key = cat.name
            byNameAmount[key, default: 0] += dataStore.amountInBase(tx)
            byNameCount[key, default: 0] += 1
            if byNameCategory[key] == nil { byNameCategory[key] = cat }
        }

        return byNameAmount.compactMap { name, amount in
            guard let cat = byNameCategory[name] else { return nil }
            let percentage = Double(amount) / Double(total) * 100.0
            let count = byNameCount[name, default: 0]
            return CategoryBreakdownItem(
                category: cat,
                amount: amount,
                percentage: percentage,
                txCount: count
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    // MARK: - Computed: transfer breakdown (directions between accounts)

    struct TransferBreakdownItem: Identifiable, Sendable {
        var id: String { directionKey }
        let directionKey: String        // "\(fromId ?? "ext")→\(toId ?? "ext")"
        let fromAccountId: String?      // nil = external / not visible (RLS)
        let toAccountId: String?
        let fromLabel: String           // "💳 Тинькофф" or localized "external"
        let toLabel: String
        let fromIcon: String            // account emoji for the donut label
        let colorHex: String            // deterministic palette color
        let amount: Int64               // FX-normalized, base currency kopecks
        let percentage: Double
        let txCount: Int                // transfer operations (groups), not legs
    }

    /// Groups the period's transfers into directions «Счёт А → Счёт Б».
    ///
    /// Legs sharing a `transferGroupId` collapse into ONE operation; the
    /// expense leg is canonical (its account is the source, its amount is
    /// what the user sent — correct for cross-currency pairs). A missing
    /// pair leg (partner's account hidden by RLS, or legacy solo rows)
    /// becomes an "external" endpoint. A→B and B→A stay separate.
    func transferBreakdown(from transactions: [Transaction], dataStore: DataStore) -> [TransferBreakdownItem] {
        let periodTransfers = transactions.filter { tx in
            guard tx.isTransfer else { return false }
            guard let d = Self.txDateFormatter.date(from: tx.date) else { return false }
            return isInSelectedPeriod(d)
        }
        guard !periodTransfers.isEmpty else { return [] }

        var groups: [String: [Transaction]] = [:]
        var solos: [Transaction] = []
        for tx in periodTransfers {
            if let gid = tx.transferGroupId {
                groups[gid, default: []].append(tx)
            } else {
                solos.append(tx)
            }
        }

        struct Direction {
            let from: String?
            let to: String?
            let amount: Int64
        }
        var directions: [Direction] = []

        for legs in groups.values {
            // Legacy legs may carry type == .transfer with the sign encoding
            // the direction (see TransactionRowView.transferDirectionText).
            let outLeg = legs.first { $0.type == .expense || ($0.type == .transfer && $0.amountNative < 0) }
            let inLeg = legs.first { $0.type == .income || ($0.type == .transfer && $0.amountNative > 0) }
            if let out = outLeg {
                directions.append(Direction(
                    from: out.accountId,
                    to: inLeg?.accountId,
                    amount: abs(dataStore.amountInBase(out))
                ))
            } else if let inc = inLeg {
                directions.append(Direction(
                    from: nil,
                    to: inc.accountId,
                    amount: abs(dataStore.amountInBase(inc))
                ))
            }
        }
        for tx in solos {
            let amount = dataStore.amountInBase(tx)
            if tx.amountNative < 0 {
                directions.append(Direction(from: tx.accountId, to: nil, amount: abs(amount)))
            } else {
                directions.append(Direction(from: nil, to: tx.accountId, amount: abs(amount)))
            }
        }

        // Account filter: a direction passes when EITHER endpoint matches.
        let visible = selectedAccountId == nil
            ? directions
            : directions.filter { $0.from == selectedAccountId || $0.to == selectedAccountId }

        var amountByKey: [String: Int64] = [:]
        var countByKey: [String: Int] = [:]
        var endpointsByKey: [String: (from: String?, to: String?)] = [:]
        for d in visible {
            let key = "\(d.from ?? "ext")→\(d.to ?? "ext")"
            amountByKey[key, default: 0] += d.amount
            countByKey[key, default: 0] += 1
            if endpointsByKey[key] == nil { endpointsByKey[key] = (d.from, d.to) }
        }

        let total = amountByKey.values.reduce(Int64(0), +)
        guard total > 0 else { return [] }

        let accountsById = dataStore.currencyContext.accountsById
        let externalLabel = String(localized: "report.transfers.externalAccount")

        func label(for accountId: String?) -> String {
            guard let accountId, let acc = accountsById[accountId] else { return externalLabel }
            return "\(acc.icon) \(acc.name)"
        }

        return amountByKey.map { key, amount in
            let endpoints = endpointsByKey[key] ?? (nil, nil)
            let fromIcon = endpoints.from.flatMap { accountsById[$0]?.icon } ?? "↔️"
            return TransferBreakdownItem(
                directionKey: key,
                fromAccountId: endpoints.from,
                toAccountId: endpoints.to,
                fromLabel: label(for: endpoints.from),
                toLabel: label(for: endpoints.to),
                fromIcon: fromIcon,
                colorHex: Self.directionColor(for: key),
                amount: amount,
                percentage: Double(amount) / Double(total) * 100.0,
                txCount: countByKey[key, default: 0]
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    private static let directionPalette = [
        "#60A5FA", "#4ADE80", "#F472B6", "#FBBF24",
        "#A78BFA", "#FB923C", "#F87171", "#34D399"
    ]

    /// Deterministic color per direction — djb2 over the key, NOT Swift's
    /// seeded `hashValue` (which changes across launches).
    static func directionColor(for key: String) -> String {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return directionPalette[Int(hash % UInt64(directionPalette.count))]
    }

    // MARK: - Computed: daily balance trend

    struct DailyBalancePoint: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let balance: Double
    }

    func dailyBalanceTrend(from transactions: [Transaction], dataStore: DataStore) -> [DailyBalancePoint] {
        let calendar = Calendar.current

        let comps = calendar.dateComponents([.year, .month], from: selectedMonth)
        guard let monthStart = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else {
            return []
        }

        var dailyNet: [Int: Int64] = [:]

        for tx in transactions {
            guard !tx.isTransfer else { continue }
            guard let txDate = Self.txDateFormatter.date(from: tx.date) else { continue }
            let day = calendar.component(.day, from: txDate)

            let amount = dataStore.amountInBase(tx)
            let signed: Int64 = tx.type == .income ? amount : -amount
            dailyNet[day, default: 0] += signed
        }

        var cumulative: Double = 0
        var result: [DailyBalancePoint] = []

        for day in range {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let net = dailyNet[day, default: 0]
            cumulative += Double(net) / 100.0
            result.append(DailyBalancePoint(date: date, balance: cumulative))
        }

        return result
    }

    // MARK: - Months list

    var months: [Date] {
        let calendar = Calendar.current
        let now = Date()
        let currentComps = calendar.dateComponents([.year, .month], from: now)
        guard let currentMonthStart = calendar.date(from: currentComps) else { return [] }

        return (0..<12).reversed().compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: currentMonthStart)
        }
    }

    // MARK: - Labels

    func monthLabel(_ date: Date) -> String {
        Self.monthLabelFormatter.string(from: date).capitalizedFirstLetter
    }

    func shortMonthLabel(_ date: Date) -> String {
        Self.shortMonthLabelFormatter.string(from: date).capitalizedFirstLetter
    }
}

// MARK: - String helper

private extension String {
    var capitalizedFirstLetter: String {
        guard let first = self.first else { return self }
        return String(first).uppercased() + self.dropFirst()
    }
}
