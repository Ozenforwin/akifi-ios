import SwiftUI

struct AnalyticsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = AnalyticsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }

    private var filtered: [Transaction] {
        viewModel.filteredTransactions(from: dataStore.transactions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Period Selector
                    Picker("Период", selection: $viewModel.selectedPeriod) {
                        ForEach(AnalyticsPeriod.allCases, id: \.self) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Summary
                    HStack(spacing: 12) {
                        AnalyticsSummaryCard(
                            title: "Доходы",
                            amount: appViewModel.currencyManager.formatAmount(
                                viewModel.totalIncome(from: filtered)
                            ),
                            color: .green,
                            icon: "arrow.up.right"
                        )
                        AnalyticsSummaryCard(
                            title: "Расходы",
                            amount: appViewModel.currencyManager.formatAmount(
                                viewModel.totalExpense(from: filtered)
                            ),
                            color: .red,
                            icon: "arrow.down.left"
                        )
                    }

                    // Cashflow Chart
                    CashflowChartView(data: viewModel.cashflowData(from: filtered))

                    // Category Breakdown
                    CategoryBreakdownView(
                        data: viewModel.categoryBreakdown(
                            from: filtered,
                            categories: dataStore.categories
                        )
                    )

                    // Portfolio
                    PortfolioChartView()
                }
                .padding(.horizontal)
            }
            .navigationTitle("Аналитика")
        }
    }
}

struct AnalyticsSummaryCard: View {
    let title: String
    let amount: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(amount)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
