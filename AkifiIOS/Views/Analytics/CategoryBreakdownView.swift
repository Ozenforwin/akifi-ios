import SwiftUI
import Charts

struct CategoryBreakdownView: View {
    @Environment(AppViewModel.self) private var appViewModel

    /// Owns the period filter (shared with the cashflow chart, so every
    /// widget moves in lockstep) and memoizes the breakdown per
    /// (data revision, account, period, type, categories). The body reads
    /// it exactly once; donut, list, chart-tap lookups and the drill-down
    /// sheet all work off that one value.
    let state: AnalyticsTabState

    @State private var selectedType: CategoryType = .expense
    @State private var selectedCategory: CategorySpending?
    @State private var isExpanded = false
    @State private var sheetCategory: CategorySpending?
    @State private var chartSelection: Decimal?

    private let collapsedCount = 5

    var body: some View {
        let breakdown = state.categoryBreakdown(type: selectedType)
        let data = breakdown.spending
        VStack(alignment: .leading, spacing: 12) {
            // Header: title + expense/income toggle
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer()
                    typePicker
                        .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    typePicker
                }
            }

            // Period filter is rendered once in `AnalyticsTabView` and
            // shared with the cashflow chart via `state.selectedPeriod`.

            if data.isEmpty {
                ContentUnavailableView(
                    String(localized: "report.noData"),
                    systemImage: "chart.pie"
                )
                .frame(height: 200)
            } else {
                // Interactive donut chart
                donutChart(data, total: breakdown.total)

                // Category list
                categoryListSection(data)
            }
        }
        .akifiCard()
        .sheet(item: $sheetCategory) { category in
            CategoryTransactionsSheet(
                category: category,
                transactions: breakdown.filtered.filter {
                    !$0.isTransfer && $0.categoryId == category.id
                }
            )
            .presentationDetents([.medium, .large])
        }
        .onChange(of: chartSelection) { _, newValue in
            withAnimation(.easeInOut(duration: 0.15)) {
                if let val = newValue {
                    selectedCategory = Self.findCategory(for: val, in: data)
                } else {
                    selectedCategory = nil
                }
            }
        }
    }

    private var title: some View {
        Text(String(localized: "analytics.byCategory"))
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private var typePicker: some View {
        Picker(String(localized: "common.type"), selection: $selectedType) {
            Text(String(localized: "common.expenses")).tag(CategoryType.expense)
            Text(String(localized: "common.incomes")).tag(CategoryType.income)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Donut Chart with tap selection

    private func donutChart(_ data: [CategorySpending], total: Decimal) -> some View {
        Chart(data) { item in
            SectorMark(
                angle: .value("Amount", item.amount),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(Color(hex: item.color))
            .cornerRadius(4)
            .opacity(selectedCategory == nil || selectedCategory?.id == item.id ? 1.0 : 0.3)
        }
        .chartAngleSelection(value: $chartSelection)
        .frame(height: 220)
        .chartBackground { _ in
            // Center label: selected category or total
            VStack(spacing: 2) {
                if let sel = selectedCategory {
                    Text(sel.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(sel.percentage))%")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(appViewModel.currencyManager.formatAmount(sel.amount))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(appViewModel.currencyManager.formatAmount(total))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(selectedType == .expense
                         ? String(localized: "common.expenses")
                         : String(localized: "common.incomes"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func findCategory(for value: Decimal, in data: [CategorySpending]) -> CategorySpending? {
        var cumulative: Decimal = 0
        for item in data {
            cumulative += item.amount
            if value <= cumulative { return item }
        }
        return data.last
    }

    // MARK: - Category List

    private func categoryListSection(_ data: [CategorySpending]) -> some View {
        let visibleData = isExpanded || data.count <= collapsedCount + 1
            ? data
            : Array(data.prefix(collapsedCount))
        return VStack(spacing: 0) {
            ForEach(visibleData) { item in
                let isSelected = selectedCategory?.id == item.id

                Button {
                    sheetCategory = item
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: item.color))
                            .frame(width: 10, height: 10)
                        Text(item.icon)
                            .font(.caption)
                        Text(item.name)
                            .font(isSelected ? .subheadline.weight(.semibold) : .subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(appViewModel.currencyManager.formatAmount(item.amount))
                            .font(isSelected ? .subheadline.weight(.semibold) : .subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("\(Int(item.percentage))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(selectedCategory == nil || isSelected ? 1.0 : 0.5)
            }

            // Show more / less
            if data.count > collapsedCount + 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(isExpanded
                             ? String(localized: "common.collapse")
                             : String(localized: "analytics.moreCategories.\(data.count - collapsedCount)"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accent)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Color.accent)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Category Transactions Sheet

struct CategoryTransactionsSheet: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let category: CategorySpending
    let transactions: [Transaction]

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(String(localized: "home.noTransactions"), systemImage: "tray")
                } else {
                    // A system inset-grouped list: summary on top, the
                    // rows below (was material cards on a cleared sheet).
                    List {
                        Section {
                            HStack(spacing: 12) {
                                Text(category.icon)
                                    .font(.title2)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.name)
                                        .font(.headline)
                                    Text(String(localized: "analytics.transactionsCount.\(transactions.count)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(appViewModel.currencyManager.formatAmount(category.amount))
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.expense)
                            }
                            .accessibilityElement(children: .combine)
                        }

                        Section {
                            ForEach(transactions) { tx in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tx.description ?? category.name)
                                            .font(.subheadline)
                                        Text(tx.formattedDateTime)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text("-\(appViewModel.currencyManager.formatAmount(appViewModel.dataStore.amountInBaseDisplay(tx)))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.expense)
                                        .monospacedDigit()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
    }
}

extension CategorySpending: Equatable {
    static func == (lhs: CategorySpending, rhs: CategorySpending) -> Bool {
        lhs.id == rhs.id
    }
}
