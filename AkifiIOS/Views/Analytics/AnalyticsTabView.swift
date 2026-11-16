import SwiftUI

struct AnalyticsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showAddTransaction = false

    /// Period / account filters plus every panel's memoized derivation.
    /// Bound to the store at the top of `body`, so it is usable from the
    /// first frame (see `AnalyticsTabState`).
    @State private var tabState = AnalyticsTabState()

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        let state = tabState.bind(dataStore)
        let isNewUser = state.isDemo
        NavigationStack {
            VStack(spacing: 0) {
                // Sticky account filter
                accountFilterHeader(state)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)

                ScrollView {
                    // Lazy: only on-screen panels compute on first visit;
                    // the rest prime as the user scrolls. Every panel has a
                    // bounded height so laziness doesn't cause layout jumps.
                    LazyVStack(spacing: 12) {
                        // Pre-aggregated 6-month series, scoped to the
                        // currently-selected account. Demo mode gets the
                        // empty-array contract — both consumer widgets handle
                        // a fewer-than-six list gracefully.
                        let aggregates = state.monthlyAggregates(months: 6)

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

                        // 2. Daily Limit Widget. Hidden for demo-mode users:
                        // unlike sibling panels it has no demoBlur variant,
                        // and real zero-ish numbers next to blurred demo
                        // content read as broken.
                        if !isNewUser && !dataStore.budgets.isEmpty {
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

                        // 5. Period filter (single source of truth — the
                        //    cashflow chart and the category breakdown both
                        //    read `state.selectedPeriod`).
                        WidgetFilterView(selectedPeriod: Bindable(state).selectedPeriod)

                        // 6. Cashflow Chart — buckets follow the selected
                        //    period; memoized in `state`.
                        if isNewUser {
                            CashflowChartView(state: state)
                                .demoBlur(
                                    hint: String(localized: "analytics.cashflowHint"),
                                    buttonTitle: String(localized: "welcome.addTransaction")
                                ) { showAddTransaction = true }
                        } else {
                            CashflowChartView(state: state)
                        }

                        // 7. Category Breakdown — shares the period with the
                        //    cashflow chart above (no duplicate filter row).
                        if isNewUser {
                            CategoryBreakdownView(state: state)
                                .demoBlur(
                                    hint: String(localized: "analytics.categoryHint"),
                                    buttonTitle: String(localized: "welcome.addTransaction")
                                ) { showAddTransaction = true }
                        } else {
                            CategoryBreakdownView(state: state)
                        }

                        // 8. Cash Flow Forecast — parked at the bottom until
                        //    the visual polish + content density is improved.
                        if !isNewUser {
                            CashFlowForecastView(state: state)
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
            }
        }
    }

    private func accountFilterHeader(_ state: AnalyticsTabState) -> some View {
        let selectedAccountId = state.selectedAccountId
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    state.selectedAccountId = nil
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
                        state.selectedAccountId = account.id
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
