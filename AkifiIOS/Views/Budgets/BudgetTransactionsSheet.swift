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
    let metrics: BudgetMetrics

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
        let period = BudgetMath.currentPeriod(for: budget)
        self.period = period
        transactions = BudgetMath.matchingTransactions(
            budget: budget,
            transactions: dataStore.transactions,
            period: period,
            categories: dataStore.categories
        )
        // A shared budget also counts a partner's expenses paid from
        // accounts this user can't see (RLS). They are part of
        // `metrics.spent` but have no rows to list — say so instead of
        // letting the numbers look broken.
        externalSpent = BudgetMath.externalSpent(
            rows: dataStore.externalSpendByBudget[budget.id] ?? [],
            budget: budget,
            period: period,
            currencyContext: dataStore.currencyContext
        )
        categoryIndex = Dictionary(
            dataStore.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
    }

    private static let periodFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.setLocalizedDateFormatFromTemplate("d MMM")
        return df
    }()

    private var periodLabel: String {
        "\(Self.periodFormatter.string(from: period.start)) – \(Self.periodFormatter.string(from: period.end))"
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
            ScrollView {
                // First frame renders before `.task` fills the state — an
                // empty scroll beats a summary card with zeros and a
                // distantPast period label.
                if loaded {
                    VStack(spacing: 16) {
                        summaryCard

                        if transactions.isEmpty {
                            ContentUnavailableView(
                                String(localized: "budget.history.empty"),
                                systemImage: "tray",
                                description: Text(String(localized: "budget.history.empty.description"))
                            )
                            .padding(.top, 40)
                        } else {
                            transactionsList
                        }

                        if externalSpent > 0 {
                            externalSpendNote
                        }
                    }
                    .padding()
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle(budget.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
        .background(.clear)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: dataStore.transactions.count) { reload() }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(budgetFmt(metrics.spent))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(hex: metrics.progressColor))
                Text("\(String(localized: "common.of")) \(budgetFmt(metrics.effectiveLimit))")
                    .font(.subheadline)
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
                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "analytics.transactionsCount.\(transactions.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Rows

    private var transactionsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(transactions.enumerated()), id: \.element.id) { index, tx in
                TransactionRowView(
                    transaction: tx,
                    category: tx.categoryId.flatMap { categoryIndex[$0] },
                    account: tx.accountId.flatMap { dataStore.currencyContext.accountsById[$0] }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                if index < transactions.count - 1 {
                    Divider().padding(.leading, 68)
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
    }

    private var externalSpendNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "budget.history.externalSpend.\(budgetFmt(externalSpent))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
