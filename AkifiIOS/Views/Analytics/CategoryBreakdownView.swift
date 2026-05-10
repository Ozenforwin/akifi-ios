import SwiftUI
import Charts

struct CategoryBreakdownView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let allTransactions: [Transaction]
    let categories: [Category]

    /// Period filter is owned by the enclosing tab so all widgets reading
    /// from `AnalyticsTabState.selectedPeriod` (cashflow chart, category
    /// donut, etc.) move in lockstep — no duplicate `WidgetFilterView`
    /// rows on screen.
    @Binding var selectedPeriod: WidgetPeriod
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

    // MARK: - Memoization
    //
    // `data` is consumed by both the donut chart and the list, and
    // `findCategory(for:)` reads it on every chart-tap. Re-bucketing the
    // entire transaction set on each access was the dominant cost when
    // the user scrubbed the chart. The cache key fingerprints
    // (`txCount`, `selectedType`, `selectedPeriod`) — that's enough to
    // catch every input that shapes the result while keeping the key
    // cheap to compare. Account / FX changes flow in via `allTransactions`
    // (which is itself derived from `AnalyticsTabState.scopedTransactions`,
    // already keyed on `txGenerationToken`).

    private struct CacheKey: Equatable {
        let txCount: Int
        let selectedType: CategoryType
        let selectedPeriod: WidgetPeriod
    }

    @State private var cachedKey: CacheKey?
    @State private var cachedData: [CategorySpending] = []
    @State private var cachedFiltered: [Transaction] = []

    private var currentKey: CacheKey {
        CacheKey(
            txCount: allTransactions.count,
            selectedType: selectedType,
            selectedPeriod: selectedPeriod
        )
    }

    /// Single-pass aggregation. The previous implementation walked
    /// `filteredTxs` twice (once for `total`, once for `byCategory`) and
    /// called `amountInBaseDisplay` on every tx in each pass. Folding both
    /// accumulators into one loop halves the FX-conversion work and
    /// matches what `AnalyticsViewModel.categoryBreakdown(...)` does for
    /// the AI surface.
    private func computeData() -> (filtered: [Transaction], spending: [CategorySpending]) {
        let startDate = selectedPeriod.startDate()
        let df = Self.isoDF
        let filtered = allTransactions.filter { tx in
            guard let date = df.date(from: tx.date) else { return false }
            return date >= startDate
        }

        let typed = filtered.filter { tx in
            !tx.isTransfer && (
                (selectedType == .expense && tx.type == .expense) ||
                (selectedType == .income && tx.type == .income)
            )
        }

        var total: Decimal = 0
        var byCategory: [String: Decimal] = [:]
        for tx in typed {
            // ADR-001: sum via amountInBaseDisplay so per-category totals
            // and the grand total are FX-normalized in lockstep.
            let amount = appViewModel.dataStore.amountInBaseDisplay(tx)
            total += amount
            let catId = tx.categoryId ?? "uncategorized"
            byCategory[catId, default: 0] += amount
        }

        guard total > 0 else { return (filtered, []) }

        let spending: [CategorySpending] = byCategory.compactMap { catId, amount in
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

        return (filtered, spending)
    }

    /// Memoized accessor — falls back to a synchronous compute on cache
    /// miss so the donut never renders stale data for a frame, then the
    /// `task(id:)` modifier promotes the result into `@State` for all
    /// subsequent reads (including `findCategory(for:)` taps).
    private var data: [CategorySpending] {
        if cachedKey == currentKey {
            return cachedData
        }
        return computeData().spending
    }

    private var filteredTransactions: [Transaction] {
        if cachedKey == currentKey {
            return cachedFiltered
        }
        return computeData().filtered
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

            // Period filter is rendered once in `AnalyticsTabView` and
            // shared with the cashflow chart via `tabState.selectedPeriod`.
            // (Removed local `WidgetFilterView` to avoid the duplicate row.)

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
        // Promote the freshly-computed data into `@State` once per key
        // transition. Subsequent reads of `data` / `filteredTransactions`
        // (donut redraws, list refreshes, chart-tap `findCategory`) hit
        // the cache instead of re-bucketing.
        .task(id: currentKey) {
            let key = currentKey
            if cachedKey != key {
                let result = computeData()
                cachedFiltered = result.filtered
                cachedData = result.spending
                cachedKey = key
            }
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
                    let total = data.reduce(Decimal(0)) { $0 + $1.amount } // allowlisted-amount: CategorySpending.amount is already FX-normalized via amountInBaseDisplay in `data`
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
                                    Text("-\(appViewModel.currencyManager.formatAmount(appViewModel.dataStore.amountInBaseDisplay(tx)))")
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
