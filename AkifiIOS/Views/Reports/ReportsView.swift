import SwiftUI
import Charts

struct ReportsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var vm = ReportsViewModel()
    @State private var sheetData: CategorySheetData?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    /// Pre-computed once per body for sheet opening
    struct CategorySheetData: Identifiable {
        var id: String { item.category.id }
        let item: ReportsViewModel.CategoryBreakdownItem
        let transactions: [Transaction]
    }

    var body: some View {
        let items = vm.categoryBreakdown(from: dataStore.transactions, categories: dataStore.categories)

        VStack(spacing: 0) {
            // Swipeable header (not inside ScrollView — safe for gestures)
            VStack(spacing: 0) {
                filtersBar
                periodPager

                Picker("", selection: $vm.selectedType) {
                    Text(String(localized: "common.expenses")).tag(CategoryType.expense)
                    Text(String(localized: "common.incomes")).tag(CategoryType.income)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .gesture(periodSwipeGesture)

            if items.isEmpty {
                ContentUnavailableView(
                    String(localized: "report.noData"),
                    systemImage: "chart.pie",
                    description: Text(String(localized: "report.noDataDescription"))
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        donutSection(items: items)
                            .padding(.bottom, 24)

                        categoryList(items: items)
                    }
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationTitle(String(localized: "report.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .fontWeight(.medium)
                }
            }
        }
        .sheet(item: $sheetData) { data in
            ReportCategoryDetailSheet(
                item: data.item,
                transactions: data.transactions,
                isExpense: vm.selectedType == .expense,
                cm: appViewModel.currencyManager
            )
        }
    }

    // MARK: - Full-screen swipe gesture

    private var periodSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                // Strict horizontal: width must dominate height by 2x
                guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if value.translation.width < -50 { vm.nextPeriod() }
                    else if value.translation.width > 50 { vm.previousPeriod() }
                }
            }
    }

    // MARK: - Filters Bar

    private var filtersBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button(String(localized: "budget.allAccounts")) {
                    vm.selectedAccountId = nil
                }
                ForEach(dataStore.accounts) { acc in
                    Button("\(acc.icon) \(acc.name)") {
                        vm.selectedAccountId = acc.id
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(accountLabel)
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
            }
            .foregroundStyle(.primary)

            Menu {
                ForEach(ReportsViewModel.PeriodMode.allCases, id: \.self) { mode in
                    Button(mode.label) {
                        vm.periodMode = mode
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(vm.periodMode.label)
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
            }
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 8)
    }

    private var accountLabel: String {
        if let id = vm.selectedAccountId,
           let acc = dataStore.accounts.first(where: { $0.id == id }) {
            return "\(acc.icon) \(acc.name)"
        }
        return String(localized: "budget.allAccounts")
    }

    // MARK: - Period Pager (3 columns)

    private var periodPager: some View {
        let prev = vm.prevPeriodDate()
        let next = vm.nextPeriodDate()

        return HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { vm.previousPeriod() }
            } label: {
                Text(vm.periodLabel(prev))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
            }

            Text(vm.periodLabel(vm.selectedMonth))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .lineLimit(1)

            if let next {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { vm.nextPeriod() }
                } label: {
                    Text(vm.periodLabel(next))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
            } else {
                Text("")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Donut Section

    @ViewBuilder
    private func donutSection(items: [ReportsViewModel.CategoryBreakdownItem]) -> some View {
        if !items.isEmpty {
            let total = items.reduce(Int64(0)) { $0 + $1.amount }
            ReportDonutChart(
                items: items,
                total: total,
                totalLabel: cm.formatAmount(total.displayAmount),
                typeLabel: vm.selectedType == .expense
                    ? String(localized: "common.expenses")
                    : String(localized: "common.incomes")
            )
        }
    }

    // MARK: - Category List (pre-computes transactions on tap)

    private func categoryList(items: [ReportsViewModel.CategoryBreakdownItem]) -> some View {
        let lastId = items.last?.category.id
        // Pre-filter once for all categories
        let periodTxs = vm.monthTransactions(from: dataStore.transactions)

        return VStack(spacing: 0) {
            ForEach(items, id: \.category.id) { item in
                Button {
                    // Instant: filter from already-filtered period transactions
                    let catTxs = periodTxs.filter { $0.categoryId == item.category.id }
                    sheetData = CategorySheetData(item: item, transactions: catTxs)
                } label: {
                    HStack(spacing: 12) {
                        Text(item.category.icon)
                            .font(.system(size: 16))
                            .frame(width: 40, height: 40)
                            .background(Color(hex: item.category.color).opacity(0.15))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.category.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(String(localized: "analytics.transactionsCount.\(item.txCount)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        let sign = vm.selectedType == .expense ? "-" : "+"
                        Text("\(sign)\(cm.formatAmount(item.amount.displayAmount))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if item.category.id != lastId {
                    Divider().padding(.leading, 68)
                }
            }
        }
    }
}

// MARK: - Donut Chart

private struct ReportDonutChart: View {
    let items: [ReportsViewModel.CategoryBreakdownItem]
    let total: Int64
    let totalLabel: String
    let typeLabel: String

    private let donutSize: CGFloat = 200
    private let iconRadius: CGFloat = 155
    private let totalSize: CGFloat = 340

    var body: some View {
        ZStack {
            donutChart
            linesCanvas
            iconLabels
        }
        .frame(width: totalSize, height: totalSize)
        .padding(.vertical, 8)
    }

    private var donutChart: some View {
        Chart(items, id: \.category.id) { item in
            SectorMark(
                angle: .value("Amount", item.amount),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(Color(hex: item.category.color))
        }
        .frame(width: donutSize, height: donutSize)
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(totalLabel)
                    .font(.system(size: 14, weight: .bold))
                Text(typeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var visibleItems: [ReportsViewModel.CategoryBreakdownItem] {
        Array(items.prefix(8))
    }

    private var midAngles: [Double] {
        var angles: [Double] = []
        var cumulative: Double = 0
        let start = -Double.pi / 2
        let denominator = Double(max(total, 1))

        for (index, item) in items.enumerated() {
            if index >= visibleItems.count { break }
            let fraction = Double(item.amount) / denominator
            angles.append(start + (cumulative + fraction / 2) * 2 * .pi)
            cumulative += fraction
        }
        return angles
    }

    private var center: CGPoint {
        CGPoint(x: totalSize / 2, y: totalSize / 2)
    }

    private var linesCanvas: some View {
        let vis = visibleItems
        let angles = midAngles
        let c = center
        let edge = donutSize / 2
        let target = iconRadius - 14

        return Canvas { context, _ in
            for index in vis.indices {
                let angle = angles[index]
                var path = Path()
                path.move(to: CGPoint(x: c.x + edge * cos(angle), y: c.y + edge * sin(angle)))
                path.addLine(to: CGPoint(x: c.x + target * cos(angle), y: c.y + target * sin(angle)))
                context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
            }
        }
        .frame(width: totalSize, height: totalSize)
        .allowsHitTesting(false)
    }

    private var iconLabels: some View {
        let vis = visibleItems
        let angles = midAngles
        let c = center

        return ForEach(Array(vis.enumerated()), id: \.element.category.id) { index, item in
            let angle = angles[index]
            VStack(spacing: 2) {
                Text(item.category.icon)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: item.category.color).opacity(0.15))
                    .clipShape(Circle())
                Text(String(format: "%.0f%%", item.percentage))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: item.category.color))
            }
            .position(x: c.x + iconRadius * cos(angle), y: c.y + iconRadius * sin(angle))
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Category Detail Sheet (receives pre-filtered data — instant open)

private struct ReportCategoryDetailSheet: View {
    let item: ReportsViewModel.CategoryBreakdownItem
    let transactions: [Transaction]
    let isExpense: Bool
    let cm: CurrencyManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if transactions.isEmpty {
                    ContentUnavailableView(String(localized: "home.noTransactions"), systemImage: "tray")
                        .padding(.top, 60)
                } else {
                    VStack(spacing: 16) {
                        summaryCard
                        transactionsList
                    }
                    .padding()
                }
            }
            .navigationTitle(item.category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var summaryCard: some View {
        HStack {
            Text(item.category.icon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.category.name)
                    .font(.headline)
                Text(String(localized: "analytics.transactionsCount.\(item.txCount)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(cm.formatAmount(item.amount.displayAmount))
                .font(.title3.weight(.bold))
                .foregroundStyle(isExpense ? Color.expense : Color.income)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
    }

    private var transactionsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(transactions.enumerated()), id: \.element.id) { index, tx in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tx.description ?? item.category.name)
                            .font(.subheadline)
                        Text(tx.formattedDateTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    let sign = isExpense ? "-" : "+"
                    Text("\(sign)\(cm.formatAmount(tx.amount.displayAmount))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isExpense ? Color.expense : Color.income)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if index < transactions.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
    }
}
