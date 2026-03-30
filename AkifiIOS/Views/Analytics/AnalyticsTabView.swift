import SwiftUI

struct AnalyticsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = AnalyticsViewModel()

    // Shared period filter for cashflow + categories
    @State private var selectedPeriod: WidgetPeriod = .month

    // Account filter
    @State private var selectedAccountId: String?

    private var dataStore: DataStore { appViewModel.dataStore }

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
        return allTransactions.filter { tx in
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
                        MonthlySummaryView(transactions: allTransactions)

                    // 2. Daily Limit Widget
                    if !dataStore.budgets.isEmpty {
                        DailyLimitWidgetView()
                    }

                    // 3. Portfolio
                    PortfolioChartView()

                    // 4. 6-month Trend (above cashflow)
                    CashflowTrendView(transactions: allTransactions)

                    // 5. Period filter (shared for cashflow + categories)
                    WidgetFilterView(selectedPeriod: $selectedPeriod)

                    // 6. Cashflow Chart
                    CashflowChartView(
                        data: viewModel.cashflowData(from: filteredByPeriod(selectedPeriod))
                    )

                    // 7. Category Breakdown (self-filtering)
                    CategoryBreakdownView(
                        allTransactions: allTransactions,
                        categories: dataStore.categories
                    )
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
