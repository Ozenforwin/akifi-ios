import SwiftUI

/// The spending history behind one budget card: every expense the budget
/// counted this period, newest first.
///
/// The rows come from `BudgetMath.matchingTransactions` — the very list
/// `spentAmount` sums — so the header here always agrees with the card the
/// user tapped.
struct BudgetTransactionsSheet: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let budget: Budget
    let resolved: ResolvedBudgetMetrics

    private var metrics: BudgetMetrics { resolved.metrics }
    private var dataStore: DataStore { appViewModel.dataStore }
    private var fmt: CurrencyManager { appViewModel.currencyManager }

    /// Everything below is computed ONCE per data change, not per render.
    /// These feed a scrolling list — recomputing them inside `body` meant
    /// re-filtering every transaction on every frame, which turned the
    /// scroll into a slideshow.
    @State private var transactions: [Transaction] = []
    @State private var externalSpent: Int64 = 0
    @State private var categoryIndex: [String: Category] = [:]
    @State private var period: (start: Date, end: Date) = (.distantPast, .distantFuture)
    /// `.task` fires after the first frame — without this guard the sheet
    /// flashes the empty state before the rows land.
    @State private var loaded = false

    private func reload() {
        defer { loaded = true }
        // The header's window — the server's when the numbers are the
        // server's — so the list and the total cover the same days.
        let period = metrics.periodStart != .distantPast
            ? (start: metrics.periodStart, end: metrics.periodEnd)
            : BudgetMath.currentPeriod(for: budget)
        self.period = period
        // The server's author rule — the list must be the rows the total sums.
        let members = BudgetMath.memberIds(
            for: budget, viewerId: dataStore.profile?.id,
            budgetMembers: dataStore.budgetMembersByBudget[budget.id]
        )
        transactions = BudgetMath.matchingTransactions(
            budget: budget,
            transactions: dataStore.transactions,
            period: period,
            categories: dataStore.categories,
            members: members
        )
        // A shared budget also counts a partner's expenses paid from
        // accounts this user can't see (RLS). They are part of
        // `metrics.spent` but have no rows to list — say so instead of
        // letting the numbers look broken.
        if let server = resolved.server {
            let ctx = BudgetMetricsResolver.serverRatesContext(dataStore.currencyContext, server: server)
            let listed = BudgetMath.spentAmount(
                budget: budget, transactions: dataStore.transactions, period: period,
                categories: dataStore.categories, currencyContext: ctx, members: members
            )
            externalSpent = max(0, metrics.spent - listed)
        } else {
            externalSpent = BudgetMath.externalSpent(
                rows: dataStore.externalSpendByBudget[budget.id] ?? [],
                budget: budget,
                period: period,
                currencyContext: dataStore.currencyContext
            )
        }
        categoryIndex = Dictionary(
            dataStore.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
    }

    private var periodLabel: String {
        BudgetsViewModel.periodLabel(start: period.start, end: period.end)
    }

    /// Per-member split from the server, shown for shared budgets only.
    private var memberSplit: [ServerBudgetMetrics.MemberSpend] {
        guard let server = resolved.server, server.memberIds.count > 1 else { return [] }
        return server.byMember
    }

    private func memberName(_ userId: String) -> String {
        let profile = dataStore.profilesMap[userId] ?? dataStore.profilesMap[userId.lowercased()]
        if userId.lowercased() == dataStore.profile?.id.lowercased() {
            return String(localized: "budget.history.member.you", defaultValue: "Вы")
        }
        return profile?.fullName ?? profile?.email
            ?? String(localized: "budget.history.member.unknown", defaultValue: "Участник")
    }

    /// Mirrors `BudgetCardView.budgetFmt` — budget-local currency, no cents.
    private func budgetFmt(_ kopecks: Int64) -> String {
        if let raw = budget.currency, let code = Currency(code: raw.uppercased()) {
            return fmt.formatInCurrency(abs(kopecks).displayAmount, currency: code, wholeUnits: true)
        }
        return fmt.formatAmount(kopecks.displayAmount, wholeUnits: true)
    }

    var body: some View {
        NavigationStack {
            // A lazy system list (rows render as they scroll in) of content
            // cards on the grouped background — the same look as the
            // Budgets tab and Home's recent transactions.
            List {
                // First frame renders before `.task` fills the state — an
                // empty list beats a summary card with zeros and a
                // distantPast period label.
                if loaded {
                    cardRow { summaryCard }

                    if !memberSplit.isEmpty {
                        cardRow { memberSplitCard }
                    }

                    if transactions.isEmpty {
                        cardRow {
                            ContentUnavailableView(
                                String(localized: "budget.history.empty"),
                                systemImage: "tray",
                                description: Text(String(localized: "budget.history.empty.description"))
                            )
                            .padding(.top, 24)
                        }
                    } else {
                        ForEach(transactions) { tx in
                            TransactionRowView(
                                transaction: tx,
                                category: tx.categoryId.flatMap { categoryIndex[$0] },
                                account: tx.accountId.flatMap { dataStore.currencyContext.accountsById[$0] }
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }

                    if externalSpent > 0 {
                        cardRow { externalSpendNote }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(budget.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: dataStore.transactions.count) { reload() }
    }

    /// A full-width list row with no row chrome — the content draws its
    /// own card.
    private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(budgetFmt(metrics.spent))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(hex: metrics.progressColor))
                Text("\(String(localized: "common.of")) \(budgetFmt(metrics.effectiveLimit))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(metrics.utilization)%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color(hex: metrics.progressColor))
            }

            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "analytics.transactionsCount.\(transactions.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .akifiCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Members

    private var memberSplitCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "budget.history.byMember", defaultValue: "Кто сколько потратил"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(memberSplit, id: \.userId) { member in
                HStack {
                    Text(memberName(member.userId))
                        .font(.subheadline)
                    Spacer()
                    Text(budgetFmt(member.spent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .akifiCard()
    }

    // MARK: - Rows

    private var externalSpendNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "budget.history.externalSpend.\(budgetFmt(externalSpent))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .akifiCard(.compact)
    }
}
