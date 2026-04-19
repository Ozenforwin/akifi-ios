import SwiftUI

struct AnalyticsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = AnalyticsViewModel()
    @State private var showAddTransaction = false

    // Shared period filter for cashflow + categories
    @State private var selectedPeriod: WidgetPeriod = .month

    // Account filter
    @State private var selectedAccountId: String?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var isNewUser: Bool { dataStore.transactions.isEmpty }

    private var effectiveTransactions: [Transaction] {
        if isNewUser { return DemoData.transactions }
        if let accountId = selectedAccountId {
            return dataStore.transactions.filter { $0.accountId == accountId }
        }
        return dataStore.transactions
    }

    private var allTransactions: [Transaction] {
        if let accountId = selectedAccountId {
            return dataStore.transactions.filter { $0.accountId == accountId }
        }
        return dataStore.transactions
    }

    private static let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func filteredByPeriod(_ period: WidgetPeriod) -> [Transaction] {
        let startDate = period.startDate()
        let df = Self.isoDateFormatter
        let txs = isNewUser ? DemoData.transactions : allTransactions
        return txs.filter { tx in
            guard let date = df.date(from: tx.date) else { return false }
            return date >= startDate
        }
    }

    private var globalFiltered: [Transaction] {
        viewModel.filteredTransactions(from: allTransactions)
    }

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
                        // 1. Monthly Summary with % change
                        if isNewUser {
                            MonthlySummaryView(transactions: DemoData.transactions)
                                .demoBlur(
                                    hint: String(localized: "welcome.summaryHint"),
                                    buttonTitle: String(localized: "welcome.addTransaction")
                                ) { showAddTransaction = true }
                        } else {
                            MonthlySummaryView(transactions: allTransactions)
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
                            CashflowTrendView(transactions: DemoData.transactions)
                                .demoBlur(
                                    hint: String(localized: "analytics.trendHint"),
                                    buttonTitle: String(localized: "welcome.addTransaction")
                                ) { showAddTransaction = true }
                        } else {
                            CashflowTrendView(transactions: allTransactions)
                        }

                        // 5. Period filter
                        WidgetFilterView(selectedPeriod: $selectedPeriod)

                        // 6. Cashflow Chart
                        if isNewUser {
                            CashflowChartView(
                                data: viewModel.cashflowData(from: filteredByPeriod(selectedPeriod))
                            )
                            .demoBlur(
                                hint: String(localized: "analytics.cashflowHint"),
                                buttonTitle: String(localized: "welcome.addTransaction")
                            ) { showAddTransaction = true }
                        } else {
                            CashflowChartView(
                                data: viewModel.cashflowData(from: filteredByPeriod(selectedPeriod))
                            )
                        }

                        // 7. Category Breakdown
                        if isNewUser {
                            CategoryBreakdownView(
                                allTransactions: DemoData.transactions,
                                categories: DemoData.categories
                            )
                            .demoBlur(
                                hint: String(localized: "analytics.categoryHint"),
                                buttonTitle: String(localized: "welcome.addTransaction")
                            ) { showAddTransaction = true }
                        } else {
                            CategoryBreakdownView(
                                allTransactions: allTransactions,
                                categories: dataStore.categories
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
        }
    }

    private var accountFilterHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedAccountId = nil
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
                        selectedAccountId = account.id
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
