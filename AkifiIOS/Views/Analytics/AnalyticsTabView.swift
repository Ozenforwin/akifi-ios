import SwiftUI

struct AnalyticsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = AnalyticsViewModel()
    @State private var showAddTransaction = false

    // Lazily initialized in `.task` because `appViewModel` (and thus
    // `dataStore`) isn't available in `init`. `tabState` owns the
    // period/account filters plus memoized projections.
    @State private var tabState: AnalyticsTabState?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var isNewUser: Bool { dataStore.transactions.isEmpty }

    /// Demo-mode is handled here at the view boundary (per spec). When the
    /// user has no real transactions we feed `DemoData.transactions` into
    /// the same widgets; the live `tabState` is only consulted for real data.
    private var allTransactions: [Transaction] {
        tabState?.scopedTransactions ?? dataStore.transactions
    }

    private var periodTransactions: [Transaction] {
        tabState?.periodTransactions ?? []
    }

    private static let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func demoFilteredByPeriod(_ period: WidgetPeriod) -> [Transaction] {
        let startDate = period.startDate()
        let df = Self.isoDateFormatter
        return DemoData.transactions.filter { tx in
            guard let date = df.date(from: tx.date) else { return false }
            return date >= startDate
        }
    }

    /// Binding into `tabState.selectedPeriod` with a safe fallback while the
    /// state is still being constructed (one frame at most).
    private var periodBinding: Binding<WidgetPeriod> {
        Binding(
            get: { tabState?.selectedPeriod ?? .month },
            set: { tabState?.selectedPeriod = $0 }
        )
    }

    private var selectedAccountId: String? { tabState?.selectedAccountId }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Sticky account filter
                accountFilterHeader
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)

                ScrollView {
                    VStack(spacing: 12) {
                        // Pre-aggregated 6-month series, scoped to the
                        // currently-selected account. For demo mode we
                        // can't get this from `DataStore` (those rows are
                        // synthetic and live outside Supabase), so fall
                        // back to the empty-array contract — both consumer
                        // widgets handle a fewer-than-six list gracefully.
                        let aggregates = isNewUser
                            ? []
                            : dataStore.recentMonthlyAggregates(months: 6, accountId: selectedAccountId)

                        // 1. Monthly Summary with % change
                        if isNewUser {
                            MonthlySummaryView(aggregates: aggregates)
                                .demoBlur(
                                    hint: String(localized: "welcome.summaryHint"),
                                    buttonTitle: String(localized: "welcome.addTransaction")
                                ) { showAddTransaction = true }
                        } else {
                            MonthlySummaryView(aggregates: aggregates)
                                .spotlight(.analyticsChart)
                        }

                        // 2. Daily Limit Widget
                        if !dataStore.budgets.isEmpty {
                            DailyLimitWidgetView()
                        }

                        // 3. Portfolio
                        if !isNewUser {
                            PortfolioChartView()
                        }

                        // 4. 6-month Trend
                        if isNewUser {
                            CashflowTrendView(aggregates: aggregates)
                                .demoBlur(
                                    hint: String(localized: "analytics.trendHint"),
                                    buttonTitle: String(localized: "welcome.addTransaction")
                                ) { showAddTransaction = true }
                        } else {
                            CashflowTrendView(aggregates: aggregates)
                        }

                        // 5. Period filter (single source of truth — bound
                        //    to `tabState.selectedPeriod` so the cashflow
                        //    chart and the category breakdown move in sync).
                        WidgetFilterView(selectedPeriod: periodBinding)

                        // 6. Cashflow Chart — sub-month buckets, so it
                        //    can't read from `monthlyAggregates`. Memoizes
                        //    `cashflowData(...)` internally.
                        if isNewUser {
                            CashflowChartView(
                                transactions: demoFilteredByPeriod(periodBinding.wrappedValue),
                                period: periodBinding.wrappedValue,
                                dataStore: dataStore,
                                viewModel: viewModel
                            )
                            .demoBlur(
                                hint: String(localized: "analytics.cashflowHint"),
                                buttonTitle: String(localized: "welcome.addTransaction")
                            ) { showAddTransaction = true }
                        } else {
                            CashflowChartView(
                                transactions: periodTransactions,
                                period: periodBinding.wrappedValue,
                                dataStore: dataStore,
                                viewModel: viewModel
                            )
                        }

                        // 7. Category Breakdown — shares `selectedPeriod`
                        //    with the cashflow chart above (no duplicate
                        //    `WidgetFilterView` row inside the widget).
                        if isNewUser {
                            CategoryBreakdownView(
                                allTransactions: DemoData.transactions,
                                categories: DemoData.categories,
                                selectedPeriod: periodBinding
                            )
                            .demoBlur(
                                hint: String(localized: "analytics.categoryHint"),
                                buttonTitle: String(localized: "welcome.addTransaction")
                            ) { showAddTransaction = true }
                        } else {
                            CategoryBreakdownView(
                                allTransactions: allTransactions,
                                categories: dataStore.categories,
                                selectedPeriod: periodBinding
                            )
                        }

                        // 8. Cash Flow Forecast — parked at the bottom until
                        //    the visual polish + content density is improved.
                        if !isNewUser && !dataStore.transactions.isEmpty {
                            CashFlowForecastView()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 120)
                }
                .refreshable {
                    await appViewModel.dataStore.loadAll()
                }
            }
            .navigationTitle(String(localized: "analytics.title"))
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.displayCategories,
                    accounts: dataStore.accounts
                ) {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .task {
                // Lazy one-shot init — `appViewModel.dataStore` isn't available
                // in `init()` (Environment isn't readable there).
                if tabState == nil {
                    tabState = AnalyticsTabState(dataStore: dataStore)
                }
            }
        }
    }

    private var accountFilterHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    tabState?.selectedAccountId = nil
                } label: {
                    Text(String(localized: "common.all"))
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedAccountId == nil ? Color.accent : Color(.systemGray6))
                        .foregroundStyle(selectedAccountId == nil ? .white : .primary.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selectedAccountId == nil ? .clear : Color(.systemGray4), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                ForEach(dataStore.accounts) { account in
                    Button {
                        tabState?.selectedAccountId = account.id
                    } label: {
                        HStack(spacing: 4) {
                            Text(account.icon)
                                .font(.caption)
                            Text(account.name)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedAccountId == account.id ? Color.accent : Color(.systemGray6))
                        .foregroundStyle(selectedAccountId == account.id ? .white : .primary.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selectedAccountId == account.id ? .clear : Color(.systemGray4), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
