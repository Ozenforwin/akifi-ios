import SwiftUI
import Charts

struct CategoryBreakdownView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let allTransactions: [Transaction]
    let categories: [Category]

    @State private var selectedPeriod: WidgetPeriod = .month
    @State private var selectedType: CategoryType = .expense
    @State private var selectedCategory: CategorySpending?
    @State private var isExpanded = false
    @State private var sheetCategory: CategorySpending?

    private let collapsedCount = 5

    private static let isoDF: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var filteredTransactions: [Transaction] {
        let startDate = selectedPeriod.startDate()
        return allTransactions.filter { tx in
            guard let date = Self.isoDF.date(from: tx.date) else { return false }
            return date >= startDate
        }
    }

    private var data: [CategorySpending] {
        let txs = filteredTransactions.filter { tx in
            !tx.isTransfer && (
                (selectedType == .expense && tx.type == .expense) ||
                (selectedType == .income && tx.type == .income)
            )
        }

        let total = txs.reduce(Decimal(0)) { $0 + $1.amount.displayAmount }
        guard total > 0 else { return [] }

        var byCategory: [String: Decimal] = [:]
        for tx in txs {
            let catId = tx.categoryId ?? "uncategorized"
            byCategory[catId, default: 0] += tx.amountNative.displayAmount
        }

        return byCategory.compactMap { catId, amount in
            let cat = categories.first { $0.id == catId }
            return CategorySpending(
                id: catId,
                name: cat?.name ?? String(localized: "common.other"),
                icon: cat?.icon ?? "💰",
                color: cat?.color ?? "#94A3B8",
                amount: amount,
                percentage: Double(truncating: (amount / total * 100) as NSDecimalNumber)
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    private var visibleData: [CategorySpending] {
        if isExpanded || data.count <= collapsedCount + 1 {
            return data
        }
        return Array(data.prefix(collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: title + expense/income toggle
            HStack {
                Text(String(localized: "analytics.byCategory"))
                    .font(.headline)
                Spacer()
                Picker("", selection: $selectedType) {
                    Text(String(localized: "common.expenses")).tag(CategoryType.expense)
                    Text(String(localized: "common.incomes")).tag(CategoryType.income)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            // Period filter
            WidgetFilterView(selectedPeriod: $selectedPeriod)

            if data.isEmpty {
                ContentUnavailableView(
                    String(localized: "report.noData"),
                    systemImage: "chart.pie"
                )
                .frame(height: 200)
            } else {
                // Interactive donut chart
                donutChart

                // Category list
                categoryListSection
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        .sheet(item: $sheetCategory) { category in
            CategoryTransactionsSheet(
                category: category,
                transactions: filteredTransactions.filter {
                    !$0.isTransfer && $0.categoryId == category.id
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Donut Chart with tap selection

    private var donutChart: some View {
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
                        .font(.title2.bold())
                    Text(appViewModel.currencyManager.formatAmount(sel.amount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let total = data.reduce(Decimal(0)) { $0 + $1.amount }
                    Text(appViewModel.currencyManager.formatAmount(total))
                        .font(.system(size: 14, weight: .bold))
                    Text(selectedType == .expense
                         ? String(localized: "common.expenses")
                         : String(localized: "common.incomes"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: chartSelection) { _, newValue in
            withAnimation(.easeInOut(duration: 0.15)) {
                if let val = newValue {
                    selectedCategory = findCategory(for: val)
                } else {
                    selectedCategory = nil
                }
            }
        }
    }

    @State private var chartSelection: Decimal?

    private func findCategory(for value: Decimal) -> CategorySpending? {
        var cumulative: Decimal = 0
        for item in data {
            cumulative += item.amount
            if value <= cumulative { return item }
        }
        return data.last
    }

    // MARK: - Category List

    private var categoryListSection: some View {
        VStack(spacing: 0) {
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
                            .foregroundStyle(.primary)
                        Text("\(Int(item.percentage))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
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
            ScrollView {
                if transactions.isEmpty {
                    ContentUnavailableView(String(localized: "home.noTransactions"), systemImage: "tray")
                        .padding(.top, 60)
                } else {
                    VStack(spacing: 16) {
                        // Summary
                        HStack {
                            Text(category.icon)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                    .font(.headline)
                                Text(String(localized: "analytics.transactionsCount.\(transactions.count)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(appViewModel.currencyManager.formatAmount(category.amount))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.expense)
                        }
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.3), lineWidth: 0.5)
                        )

                        // Transactions
                        LazyVStack(spacing: 0) {
                            ForEach(Array(transactions.enumerated()), id: \.element.id) { index, tx in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tx.description ?? category.name)
                                            .font(.subheadline)
                                        Text(tx.formattedDateTime)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("-\(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.expense)
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)

                                if index < transactions.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .padding()
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
        .background(.clear)
    }
}

extension CategorySpending: Equatable {
    static func == (lhs: CategorySpending, rhs: CategorySpending) -> Bool {
        lhs.id == rhs.id
    }
}
