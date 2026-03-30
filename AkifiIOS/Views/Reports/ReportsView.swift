import SwiftUI
import Charts

struct ReportsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var vm = ReportsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Month swiper
                monthSwiper

                // Expense / Income segment
                Picker("", selection: $vm.selectedType) {
                    Text(String(localized: "common.expenses")).tag(CategoryType.expense)
                    Text(String(localized: "common.incomes")).tag(CategoryType.income)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Summary cards
                summaryCards

                // Daily trend chart
                trendChart

                // Category donut + list
                categorySection

                // Transactions for the month
                transactionsList
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(String(localized: "report.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Month Swiper

    private var monthSwiper: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(vm.months, id: \.self) { month in
                        let isSelected = Calendar.current.isDate(month, equalTo: vm.selectedMonth, toGranularity: .month)
                        Button {
                            withAnimation { vm.selectedMonth = month }
                        } label: {
                            Text(vm.shortMonthLabel(month))
                                .font(isSelected ? .subheadline.bold() : .subheadline)
                                .foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .id(month)
                    }
                }
                .padding(.horizontal)
            }
            .onAppear {
                proxy.scrollTo(vm.selectedMonth, anchor: .center)
            }
            .onChange(of: vm.selectedMonth) {
                withAnimation { proxy.scrollTo(vm.selectedMonth, anchor: .center) }
            }
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let txs = vm.monthTransactions(from: dataStore.transactions)
        let income = vm.monthIncome(from: txs)
        let expense = vm.monthExpense(from: txs)

        return HStack(spacing: 8) {
            summaryCard(
                title: String(localized: "report.totalBalance"),
                amount: income - expense,
                color: income >= expense ? .income : .expense
            )
            summaryCard(
                title: String(localized: "report.monthlyFlow"),
                amount: -expense,
                color: .expense
            )
        }
        .padding(.horizontal)
    }

    private func summaryCard(title: String, amount: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cm.formatAmount(amount.displayAmount))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        let points = vm.dailyBalanceTrend(from: dataStore.transactions)

        return Group {
            if points.count > 1 {
                Chart(points, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", point.balance)
                    )
                    .foregroundStyle(Color.income)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", point.balance)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.income.opacity(0.2), Color.income.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(abbreviate(v))
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { value in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 180)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Category Section

    private var categorySection: some View {
        let breakdown = vm.categoryBreakdown(from: dataStore.transactions, categories: dataStore.categories)

        return VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "report.categories"))
                .font(.title3.bold())
                .padding(.horizontal)

            // Donut chart
            if !breakdown.isEmpty {
                Chart(breakdown, id: \.category.id) { item in
                    SectorMark(
                        angle: .value("Amount", item.amount),
                        innerRadius: .ratio(0.55),
                        angularInset: 1
                    )
                    .foregroundStyle(Color(hex: item.category.color))
                }
                .frame(height: 200)
                .padding(.horizontal, 40)
            }

            // Category list
            VStack(spacing: 0) {
                ForEach(breakdown, id: \.category.id) { item in
                    HStack(spacing: 12) {
                        Text(item.category.icon)
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: item.category.color).opacity(0.15))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.category.name)
                                .font(.subheadline.weight(.medium))
                            Text("\(item.txCount) \(String(localized: "categories.transactions"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(cm.formatAmount(item.amount.displayAmount))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(vm.selectedType == .expense ? Color.expense : Color.income)
                            Text(String(format: "%.1f%%", item.percentage))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                    if item.category.id != breakdown.last?.category.id {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
    }

    // MARK: - Transactions List

    private var transactionsList: some View {
        let txs = vm.monthTransactions(from: dataStore.transactions)
            .filter { tx in
                if vm.selectedType == .expense { return tx.type == .expense && !tx.isTransfer }
                return tx.type == .income && !tx.isTransfer
            }

        let grouped = Dictionary(grouping: txs) { $0.date }
        let sortedDays = grouped.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: 8) {
            if !sortedDays.isEmpty {
                Text(String(localized: "report.transactions"))
                    .font(.title3.bold())
                    .padding(.horizontal)
            }

            ForEach(sortedDays, id: \.self) { day in
                if let dayTxs = grouped[day] {
                    Section {
                        ForEach(dayTxs) { tx in
                            TransactionRowView(
                                transaction: tx,
                                category: dataStore.category(for: tx)
                            )
                            .padding(.horizontal)
                        }
                    } header: {
                        Text(day)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func abbreviate(_ value: Double) -> String {
        let abs = abs(value)
        let sign = value < 0 ? "-" : ""
        if abs >= 1_000_000 { return "\(sign)\(String(format: "%.0f", abs / 1_000_000))M" }
        if abs >= 1_000 { return "\(sign)\(String(format: "%.0f", abs / 1_000))k" }
        return "\(sign)\(String(format: "%.0f", abs))"
    }
}
