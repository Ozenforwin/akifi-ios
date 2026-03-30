import SwiftUI
import Charts

struct ReportsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var vm = ReportsViewModel()
    @State private var selectedCategoryItem: ReportsViewModel.CategoryBreakdownItem?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var breakdown: [ReportsViewModel.CategoryBreakdownItem] {
        vm.categoryBreakdown(from: dataStore.transactions, categories: dataStore.categories)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filters bar
            filtersBar

            // Month swiper (swipeable pages)
            monthPager

            ScrollView {
                VStack(spacing: 20) {
                    // Expense / Income segment
                    Picker("", selection: $vm.selectedType) {
                        Text(String(localized: "common.expenses")).tag(CategoryType.expense)
                        Text(String(localized: "common.incomes")).tag(CategoryType.income)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    // Donut chart with icons
                    donutSection

                    // Category list
                    categoryList
                }
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(String(localized: "report.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCategoryItem) { item in
            ReportCategoryDetailSheet(item: item, vm: vm, dataStore: dataStore)
        }
    }

    // MARK: - Filters Bar

    private var filtersBar: some View {
        HStack(spacing: 8) {
            // Account picker
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

            // Period picker
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

    // MARK: - Month Pager

    private var monthPager: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(vm.months, id: \.self) { month in
                        let isSelected = Calendar.current.isDate(month, equalTo: vm.selectedMonth, toGranularity: .month)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { vm.selectedMonth = month }
                        } label: {
                            Text(vm.shortMonthLabel(month))
                                .font(isSelected ? .subheadline.bold() : .subheadline)
                                .foregroundStyle(isSelected ? .primary : .tertiary)
                                .padding(.vertical, 4)
                                .overlay(alignment: .bottom) {
                                    if isSelected {
                                        Rectangle()
                                            .fill(Color.accent)
                                            .frame(height: 2)
                                            .offset(y: 4)
                                    }
                                }
                        }
                        .id(month)
                    }
                }
                .padding(.horizontal)
            }
            .onAppear { proxy.scrollTo(vm.selectedMonth, anchor: .center) }
            .onChange(of: vm.selectedMonth) {
                withAnimation { proxy.scrollTo(vm.selectedMonth, anchor: .center) }
            }
        }
        .padding(.bottom, 8)
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width < -50 { vm.nextMonth() }
                    else if value.translation.width > 50 { vm.previousMonth() }
                }
        )
    }

    // MARK: - Donut Section

    private var donutSection: some View {
        let items = breakdown

        return Group {
            if !items.isEmpty {
                ZStack {
                    // Donut chart
                    Chart(items, id: \.category.id) { item in
                        SectorMark(
                            angle: .value("Amount", item.amount),
                            innerRadius: .ratio(0.55),
                            angularInset: 1.5
                        )
                        .foregroundStyle(Color(hex: item.category.color))
                    }
                    .frame(height: 220)
                    .padding(.horizontal, 50)
                    .chartBackground { _ in
                        // Center text
                        VStack(spacing: 2) {
                            let total = items.reduce(Int64(0)) { $0 + $1.amount }
                            Text(cm.formatAmount(total.displayAmount))
                                .font(.system(size: 14, weight: .bold))
                            Text(vm.selectedType == .expense
                                 ? String(localized: "common.expenses")
                                 : String(localized: "common.incomes"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Icons around donut
                    GeometryReader { geo in
                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let radius = min(geo.size.width, geo.size.height) / 2 + 5
                        ForEach(Array(items.prefix(8).enumerated()), id: \.element.category.id) { index, item in
                            let angle = angleFor(index: index, total: min(items.count, 8))
                            let x = center.x + radius * cos(angle)
                            let y = center.y + radius * sin(angle)

                            VStack(spacing: 1) {
                                Text(item.category.icon)
                                    .font(.caption)
                                    .frame(width: 24, height: 24)
                                    .background(Color(hex: item.category.color).opacity(0.2))
                                    .clipShape(Circle())
                                Text(String(format: "%.0f%%", item.percentage))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color(hex: item.category.color))
                            }
                            .position(x: x, y: y)
                        }
                    }
                    .frame(height: 220)
                }
                .padding(.horizontal)
                .onTapGesture {
                    // Tap donut = show first category
                    if let first = items.first { selectedCategoryItem = first }
                }
            }
        }
    }

    private func angleFor(index: Int, total: Int) -> Double {
        let start = -Double.pi / 2
        let step = (2 * Double.pi) / Double(total)
        return start + step * Double(index)
    }

    // MARK: - Category List

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(breakdown, id: \.category.id) { item in
                Button {
                    selectedCategoryItem = item
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: item.category.color))
                            .frame(width: 10, height: 10)

                        Text(item.category.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("\(String(format: "%.0f%%", item.percentage)) (\(cm.formatAmount(item.amount.displayAmount)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                if item.category.id != breakdown.last?.category.id {
                    Divider().padding(.leading, 36)
                }
            }
        }
    }
}

// MARK: - Category Detail Sheet (same design as CategoryBreakdownView)

private struct ReportCategoryDetailSheet: View {
    let item: ReportsViewModel.CategoryBreakdownItem
    let vm: ReportsViewModel
    let dataStore: DataStore
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    private var transactions: [Transaction] {
        vm.monthTransactions(from: dataStore.transactions)
            .filter { $0.categoryId == item.category.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(String(localized: "home.noTransactions"), systemImage: "tray")
                } else {
                    List {
                        // Summary card
                        Section {
                            HStack {
                                Text(item.category.icon)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.category.name)
                                        .font(.headline)
                                    Text("\(item.txCount) \(String(localized: "categories.transactions"))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(appViewModel.currencyManager.formatAmount(item.amount.displayAmount))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(vm.selectedType == .expense ? Color.expense : Color.income)
                            }
                        }

                        // Transaction rows
                        Section {
                            ForEach(transactions) { tx in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tx.description ?? item.category.name)
                                            .font(.subheadline)
                                        Text(tx.date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    let sign = vm.selectedType == .expense ? "-" : "+"
                                    Text("\(sign)\(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(vm.selectedType == .expense ? Color.expense : Color.income)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
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
    }
}
