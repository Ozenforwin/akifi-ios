import SwiftUI

struct TransactionsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = TransactionsViewModel()
    @State private var showAddTransaction = false
    @State private var showTransfer = false
    @State private var editingTransaction: Transaction?
    @State private var showFilters = false
    @State private var filterAccountId: String?
    @State private var filterDateFrom: Date?
    @State private var filterDateTo: Date?
    @State private var filterType: TransactionTypeFilter = .all

    private var dataStore: DataStore { appViewModel.dataStore }

    private static let isoDF: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var displayedTransactions: [Transaction] {
        let base = viewModel.filteredTransactions(from: dataStore.transactions)
        let df = Self.isoDF
        let cal = Calendar.current
        let fromDate = filterDateFrom.map { cal.startOfDay(for: $0) }
        let toDate = filterDateTo.map { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0))! }

        // Single-pass filter for all criteria
        return base.filter { tx in
            // Type
            switch filterType {
            case .all: break
            case .expense: guard tx.type == .expense && !tx.isTransfer else { return false }
            case .income: guard tx.type == .income && !tx.isTransfer else { return false }
            case .transfer: guard tx.isTransfer else { return false }
            }
            // Account
            if let accountId = filterAccountId, tx.accountId != accountId { return false }
            // Date range
            if fromDate != nil || toDate != nil {
                guard let d = df.date(from: tx.date) else { return true }
                if let from = fromDate, d < from { return false }
                if let to = toDate, d > to { return false }
            }
            return true
        }
    }

    private var hasActiveFilters: Bool {
        filterAccountId != nil || filterDateFrom != nil || filterDateTo != nil || filterType != .all
    }

    private var summaryTotals: (income: Int64, expense: Int64, transfer: Int64) {
        var inc: Int64 = 0
        var exp: Int64 = 0
        var trf: Int64 = 0
        var seenGroups: Set<String> = []
        for tx in displayedTransactions {
            if let gid = tx.transferGroupId {
                if !seenGroups.contains(gid) {
                    seenGroups.insert(gid)
                    trf += tx.amount
                }
                continue
            }
            if tx.isTransfer { trf += tx.amount; continue }
            if tx.type == .income { inc += tx.amount }
            else if tx.type == .expense { exp += tx.amount }
        }
        return (inc, exp, trf)
    }

    var body: some View {
        @Bindable var vm = viewModel
        NavigationStack {
            List {
                if hasActiveFilters {
                    // Filter indicator + reset
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(Color.accent)
                        Text(String(localized: "transactions.filtersActive"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "transactions.reset")) {
                            filterAccountId = nil
                            filterDateFrom = nil
                            filterDateTo = nil
                            filterType = .all
                        }
                        .font(.caption)
                    }
                    .listRowSeparator(.hidden)

                    // Summary cells: income / expense / transfer
                    HStack(spacing: 8) {
                        summaryCellView(
                            label: String(localized: "common.income"),
                            amount: summaryTotals.income,
                            color: Color.income,
                            icon: "arrow.up.right",
                            isActive: filterType == .income
                        ) { filterType = filterType == .income ? .all : .income }

                        summaryCellView(
                            label: String(localized: "common.expense"),
                            amount: summaryTotals.expense,
                            color: Color.expense,
                            icon: "arrow.down.left",
                            isActive: filterType == .expense
                        ) { filterType = filterType == .expense ? .all : .expense }

                        summaryCellView(
                            label: String(localized: "common.transfer"),
                            amount: summaryTotals.transfer,
                            color: Color.transfer,
                            icon: "arrow.left.arrow.right",
                            isActive: filterType == .transfer
                        ) { filterType = filterType == .transfer ? .all : .transfer }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                ForEach(displayedTransactions) { transaction in
                    TransactionRowView(
                        transaction: transaction,
                        category: dataStore.category(for: transaction)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingTransaction = transaction
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await dataStore.deleteTransaction(transaction) }
                        } label: {
                            Label(String(localized: "common.delete"), systemImage: "trash.fill")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingTransaction = transaction
                        } label: {
                            Label(String(localized: "common.edit"), systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }

                // Bottom spacer for tab bar
                Color.clear.frame(height: 120)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle(String(localized: "transactions.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(String(localized: "transactions.filters"))
                }
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts
                ) {
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $editingTransaction) { tx in
                TransactionFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts,
                    editingTransaction: tx
                ) {
                    await dataStore.loadAll()
                }
            }
            .sheet(isPresented: $showTransfer) {
                TransferFormView(accounts: dataStore.accounts) {
                    await dataStore.loadAll()
                }
            }
            .sheet(isPresented: $showFilters) {
                TransactionFilterSheet(
                    accounts: dataStore.accounts,
                    selectedAccountId: $filterAccountId,
                    dateFrom: $filterDateFrom,
                    dateTo: $filterDateTo,
                    selectedType: $filterType
                )
                .presentationDetents([.fraction(0.65), .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
    private func summaryCellView(label: String, amount: Int64, color: Color, icon: String, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(color)

                Text(appViewModel.currencyManager.formatAmount(amount.displayAmount))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                isActive
                    ? color.opacity(0.15)
                    : color.opacity(0.06)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? color.opacity(0.4) : color.opacity(0.12), lineWidth: isActive ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transaction Type Filter

enum TransactionTypeFilter: CaseIterable {
    case all, expense, income, transfer

    var label: String {
        switch self {
        case .all: String(localized: "common.all")
        case .expense: String(localized: "common.expenses")
        case .income: String(localized: "common.incomes")
        case .transfer: String(localized: "common.transfers")
        }
    }

    var color: Color {
        switch self {
        case .all: return .accent
        case .expense: return .expense
        case .income: return .income
        case .transfer: return .transfer
        }
    }
}

// MARK: - Filter Sheet

struct TransactionFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accounts: [Account]
    @Binding var selectedAccountId: String?
    @Binding var dateFrom: Date?
    @Binding var dateTo: Date?
    @Binding var selectedType: TransactionTypeFilter

    @State private var selectedPeriod: FilterPeriod = .all
    @State private var showCalendar = false
    @State private var calendarFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var calendarTo = Date()

    enum FilterPeriod: CaseIterable {
        case all, today, week, month

        var label: String {
            switch self {
            case .all: String(localized: "common.all")
            case .today: String(localized: "filter.today")
            case .week: String(localized: "filter.week")
            case .month: String(localized: "filter.month")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(String(localized: "transactions.filters"))
                        .font(.title2.weight(.bold))
                        .padding(.horizontal)

                    // Type filter
                    filterSection(title: String(localized: "transactions.filterType")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TransactionTypeFilter.allCases, id: \.self) { type in
                                    filterChip(
                                        label: type.label,
                                        isSelected: selectedType == type,
                                        activeColor: type.color
                                    ) {
                                        selectedType = type
                                    }
                                }
                            }
                        }
                    }

                    // Period filter
                    filterSection(title: String(localized: "transactions.filterPeriod")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                            ForEach(FilterPeriod.allCases, id: \.self) { period in
                                filterChip(
                                    label: period.label,
                                    isSelected: selectedPeriod == period && !showCalendar,
                                    activeColor: .accent
                                ) {
                                    selectedPeriod = period
                                    showCalendar = false
                                }
                            }

                            // Calendar button
                            Button {
                                showCalendar.toggle()
                                if showCalendar {
                                    selectedPeriod = .all
                                }
                            } label: {
                                Image(systemName: "calendar")
                                    .font(.subheadline)
                                    .frame(width: 40, height: 36)
                                    .background(showCalendar ? Color.accent : Color(.systemGray6))
                                    .foregroundStyle(showCalendar ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(showCalendar ? .clear : Color(.systemGray4), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        }
                    }

                    // Calendar date pickers
                    if showCalendar {
                        VStack(spacing: 12) {
                            DatePicker(String(localized: "filter.from"), selection: $calendarFrom, displayedComponents: .date)
                                .datePickerStyle(.compact)
                            DatePicker(String(localized: "filter.to"), selection: $calendarTo, displayedComponents: .date)
                                .datePickerStyle(.compact)
                        }
                        .padding(.horizontal)
                    }

                    // Account filter
                    filterSection(title: String(localized: "transactions.filterAccount")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterChip(
                                    label: String(localized: "budget.allAccounts"),
                                    isSelected: selectedAccountId == nil,
                                    activeColor: .accent
                                ) {
                                    selectedAccountId = nil
                                }

                                ForEach(accounts) { account in
                                    filterChip(
                                        icon: account.icon,
                                        label: account.name,
                                        isSelected: selectedAccountId == account.id,
                                        activeColor: .accent
                                    ) {
                                        selectedAccountId = account.id
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 20)
            }

            // Apply button
            VStack {
                Button {
                    applyFilters()
                    dismiss()
                } label: {
                    Text(String(localized: "common.apply"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentCyan)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if dateFrom != nil {
                showCalendar = true
                calendarFrom = dateFrom ?? Date()
                calendarTo = dateTo ?? Date()
            }
        }
    }

    // MARK: - Reusable Components

    private func filterSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            content()
                .padding(.horizontal)
        }
    }

    private func filterChip(icon: String? = nil, label: String, isSelected: Bool, activeColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Text(icon)
                        .font(.caption)
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? activeColor.opacity(0.15) : Color(.systemGray6))
            .foregroundStyle(isSelected ? activeColor : .primary.opacity(0.7))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? activeColor.opacity(0.3) : Color(.systemGray4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apply

    private func applyFilters() {
        if showCalendar {
            dateFrom = calendarFrom
            dateTo = calendarTo
            return
        }

        let calendar = Calendar.current
        let now = Date()

        switch selectedPeriod {
        case .all:
            dateFrom = nil
            dateTo = nil
        case .today:
            dateFrom = calendar.startOfDay(for: now)
            dateTo = now
        case .week:
            dateFrom = calendar.date(byAdding: .day, value: -7, to: now)
            dateTo = now
        case .month:
            dateFrom = calendar.date(byAdding: .month, value: -1, to: now)
            dateTo = now
        }
    }
}
