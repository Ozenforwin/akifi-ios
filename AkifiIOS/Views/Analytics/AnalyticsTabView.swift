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
                    //    read `state.selectedPeriod`). A system segmented
                    //    control right above the two panels it drives.
                    WidgetFilterView(selectedPeriod: Bindable(state).selectedPeriod)
                        .padding(.top, 8)

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
            }
            // The system insets content for the tab bar; this is only the
            // room the floating «+» needs so the last panel can scroll clear.
            .contentMargins(.bottom, AkifiChrome.floatingButtonClearance, for: .scrollContent)
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await appViewModel.dataStore.loadAll()
            }
            .navigationTitle(String(localized: "analytics.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // The account scope applies to every panel, so it lives in
                // the navigation bar — reachable and visible at any scroll
                // position (it was a sticky chip row on an opaque bar).
                ToolbarItem(placement: .topBarTrailing) {
                    AnalyticsAccountFilterMenu(
                        accounts: dataStore.accounts,
                        selectedAccountId: Bindable(state).selectedAccountId
                    )
                }
            }
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
}

// MARK: - Account filter

/// Toolbar menu scoping Analytics to one account or all of them. The label
/// names the current scope; the menu is a system inline picker (checkmark
/// on the selected row).
struct AnalyticsAccountFilterMenu: View {
    let accounts: [Account]
    @Binding var selectedAccountId: String?

    /// Title of the current scope: the selected account's name, «All
    /// accounts» when none is selected — or when the selected one is gone
    /// (deleted / left a shared account), so the label never names an
    /// account that no longer filters anything.
    nonisolated static func scopeTitle(selectedAccountId: String?, accounts: [Account], allTitle: String) -> String {
        guard let selectedAccountId,
              let account = accounts.first(where: { $0.id == selectedAccountId })
        else { return allTitle }
        return account.name
    }

    var body: some View {
        let title = Self.scopeTitle(
            selectedAccountId: selectedAccountId,
            accounts: accounts,
            allTitle: String(localized: "budget.allAccounts")
        )
        Menu {
            Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                Text(String(localized: "budget.allAccounts"))
                    .tag(String?.none)
                ForEach(accounts) { account in
                    Text(verbatim: "\(account.icon) \(account.name)")
                        .tag(String?.some(account.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel(String(localized: "common.account"))
        .accessibilityValue(Text(verbatim: title))
    }
}
