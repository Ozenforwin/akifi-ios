import SwiftUI

struct TransactionsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = TransactionsViewModel()
    @State private var showAddTransaction = false
    @State private var showTransfer = false
    @State private var editingTransaction: Transaction?
    @State private var showFilters = false
    @State private var filterAccountIds: Set<String> = []
    @State private var filterDateFrom: Date?
    @State private var filterDateTo: Date?
    @State private var filterType: TransactionTypeFilter = .all
    @State private var filterCategoryIds: Set<String> = []
    @State private var showReports = false
    /// `.searchable` text (1.6: the system search field replaced the
    /// search sheet). Narrows the list on top of the filters.
    @State private var searchQuery = ""
    @State private var searchHistory: [String] = []
    private let searchHistoryStore = TransactionSearchHistory()

    private var dataStore: DataStore { appViewModel.dataStore }

    private static var isoDF: DateFormatter { AppDateFormatters.isoDate }

    private var isSearching: Bool { !searchQuery.isEmpty }

    private var displayedTransactions: [Transaction] {
        let base = viewModel.filteredTransactions(from: dataStore.transactions)
        let query = searchQuery
        let df = Self.isoDF
        let cal = Calendar.current
        let fromDate = filterDateFrom.map { cal.startOfDay(for: $0) }
        let toDate = filterDateTo.map { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0))! }
        // B6: chips are `displayCategories` (one per name + type), so a chip
        // must match every member's same-named category, not just the id it
        // happens to carry — otherwise each member of a shared account got
        // a different list and different totals for «Продукты».
        let categoryFilter = TransactionCategoryFilter(
            selectedIds: filterCategoryIds,
            categories: dataStore.categories
        )

        // Single-pass filter for all criteria
        var seenTransferGroups: Set<String> = []
        return base.filter { tx in
            // Deduplicate transfers: show only one per transfer_group_id
            if let groupId = tx.transferGroupId {
                if seenTransferGroups.contains(groupId) { return false }
                seenTransferGroups.insert(groupId)
            }
            // Type
            switch filterType {
            case .all: break
            case .expense: guard tx.type == .expense && !tx.isTransfer else { return false }
            case .income: guard tx.type == .income && !tx.isTransfer else { return false }
            case .transfer: guard tx.isTransfer else { return false }
            }
            // Account (multi-select)
            if !filterAccountIds.isEmpty, let accId = tx.accountId, !filterAccountIds.contains(accId) { return false }
            // Category (multi-select)
            let category = dataStore.category(for: tx)
            if !categoryFilter.matches(tx, category: category) { return false }
            // Search text
            if !TransactionSearch.matches(tx, query: query, categoryName: category?.name) { return false }
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
        !filterAccountIds.isEmpty || !filterCategoryIds.isEmpty || filterDateFrom != nil || filterDateTo != nil || filterType != .all
    }

    /// M7: the filtered list spans accounts in different currencies, so
    /// every row is FX-normalised into base before summing — `$50 + 3 000 ₽`
    /// used to read «3 050 ₽». `formatAmount` then converts base → display.
    private var summaryTotals: (income: Int64, expense: Int64, transfer: Int64) {
        Self.summaryTotals(displayedTransactions, amountInBase: dataStore.amountInBase)
    }

    static func summaryTotals(
        _ transactions: [Transaction],
        amountInBase: (Transaction) -> Int64
    ) -> (income: Int64, expense: Int64, transfer: Int64) {
        var inc: Int64 = 0
        var exp: Int64 = 0
        var trf: Int64 = 0
        var seenGroups: Set<String> = []
        for tx in transactions {
            if let gid = tx.transferGroupId {
                if !seenGroups.contains(gid) {
                    seenGroups.insert(gid)
                    trf += abs(amountInBase(tx))
                }
                continue
            }
            if tx.isTransfer { trf += abs(amountInBase(tx)); continue }
            if tx.type == .income { inc += amountInBase(tx) }
            else if tx.type == .expense { exp += amountInBase(tx) }
        }
        return (inc, exp, trf)
    }

    var body: some View {
        NavigationStack {
            List {
                // Mini dashboard (hidden while filtering or searching — the
                // list then shows only the matching rows)
                if !hasActiveFilters && !isSearching {
                    TransactionsMiniDashboardView(
                        transactions: dataStore.transactions
                    ) {
                        showReports = true
                    }
                    .spotlight(.transactionsList)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }

                if hasActiveFilters {
                    // Filter indicator + reset
                    HStack {
                        Label(String(localized: "transactions.filtersActive"), systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "transactions.reset")) {
                            filterAccountIds = []
                            filterCategoryIds = []
                            filterDateFrom = nil
                            filterDateTo = nil
                            filterType = .all
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

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

                if displayedTransactions.isEmpty {
                    if isSearching {
                        ContentUnavailableView.search(text: searchQuery)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else if !hasActiveFilters {
                        EmptyStateView(
                            title: String(localized: "transactions.empty.title"),
                            systemImage: "tray.fill",
                            description: String(localized: "transactions.empty.description"),
                            actionTitle: String(localized: "welcome.addTransaction")
                        ) {
                            showAddTransaction = true
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
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
                        // Opening a result is a search worth remembering.
                        if isSearching { rememberSearch(searchQuery) }
                        editingTransaction = transaction
                    }
                    .accessibilityAddTraits(.isButton)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        // An auto-transfer the other member paid from their
                        // card can only be deleted by them (server 42501);
                        // the delete would fail silently, so don't offer it.
                        if dataStore.canModifyAutoTransfer(transaction) {
                            Button(role: .destructive) {
                                Task { await dataStore.deleteTransaction(transaction) }
                            } label: {
                                Label(String(localized: "common.delete"), systemImage: "trash.fill")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingTransaction = transaction
                        } label: {
                            Label(String(localized: "common.edit"), systemImage: "pencil")
                        }
                        .tint(Color.accent)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            // The system insets the list for the tab bar; this keeps the
            // last row clear of the floating «+».
            .contentMargins(.bottom, AkifiChrome.floatingButtonClearance, for: .scrollContent)
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle(String(localized: "transactions.title"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchQuery, prompt: String(localized: "search.prompt"))
            .searchSuggestions {
                if searchQuery.isEmpty {
                    TransactionSearchSuggestions(
                        suggestions: TransactionSearch.suggestions(from: dataStore.transactions),
                        history: searchHistory,
                        onPick: { term in
                            searchQuery = term
                            rememberSearch(term)
                        },
                        onRemove: { term in
                            searchHistory.removeAll { $0 == term }
                            searchHistoryStore.save(searchHistory)
                        },
                        onClearHistory: {
                            searchHistory = []
                            searchHistoryStore.save([])
                        }
                    )
                }
            }
            .onSubmit(of: .search) { rememberSearch(searchQuery) }
            // iOS 26: a search button in the toolbar that expands into the
            // glass field. (A bottom-bar field isn't shown inside a tab — the
            // tab bar's search role belongs to the Assistant.)
            .akifiSearchToolbarMinimize()
            .onAppear { searchHistory = searchHistoryStore.load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filterSymbol)
                    }
                    .accessibilityLabel(String(localized: "transactions.filters"))
                    .accessibilityValue(hasActiveFilters ? String(localized: "transactions.filtersActive") : "")
                }
            }
            .navigationDestination(isPresented: $showReports) {
                ReportsView()
            }
            .sheet(isPresented: $showAddTransaction) {
                TransactionFormView(
                    categories: dataStore.displayCategories,
                    accounts: dataStore.accounts
                ) {
                    // loadAll (not just rebuildCaches) — matches every other
                    // form completion: picks up server-side effects like
                    // auto-transfer triplets and subscription auto-match.
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $editingTransaction) { tx in
                // M2: an auto-transfer leg is edited through its main
                // expense (TransferFormView would re-price two of the three
                // rows). TransferFormView repeats this routing for the other
                // entry points and shows a read-only note when the expense
                // is not visible.
                if tx.isAutoTransferLeg, let main = dataStore.mainExpense(forAutoTransferLeg: tx) {
                    TransactionFormView(
                        categories: dataStore.displayCategories,
                        accounts: dataStore.accounts,
                        editingTransaction: main
                    ) {
                        await dataStore.loadAll()
                    }
                } else if tx.isTransfer {
                    TransferFormView(
                        accounts: dataStore.accounts,
                        editingTransaction: tx
                    ) {
                        await dataStore.loadAll()
                    }
                } else {
                    TransactionFormView(
                        categories: dataStore.displayCategories,
                        accounts: dataStore.accounts,
                        editingTransaction: tx
                    ) {
                        await dataStore.loadAll()
                    }
                }
            }
            .sheet(isPresented: $showTransfer) {
                TransferFormView(accounts: dataStore.accounts) {
                    dataStore.rebuildCaches()
                }
            }
            .sheet(isPresented: $showFilters) {
                TransactionFilterSheet(
                    accounts: dataStore.accounts,
                    categories: dataStore.displayCategories,
                    selectedAccountIds: $filterAccountIds,
                    selectedCategoryIds: $filterCategoryIds,
                    dateFrom: $filterDateFrom,
                    dateTo: $filterDateTo,
                    selectedType: $filterType
                )
                .presentationDetents([.fraction(0.75), .large])
            }
        }
    }

    /// Filled while filters are active. On iOS 26 the glass toolbar plate
    /// already draws the circle around the plain symbol.
    private var filterSymbol: String {
        if hasActiveFilters { return "line.3.horizontal.decrease.circle.fill" }
        return AkifiGlassRendering.current == .liquidGlass
            ? "line.3.horizontal.decrease"
            : "line.3.horizontal.decrease.circle"
    }

    private func rememberSearch(_ term: String) {
        let updated = TransactionSearchHistory.adding(term, to: searchHistory)
        guard updated != searchHistory else { return }
        searchHistory = updated
        searchHistoryStore.save(updated)
    }

    /// Type toggle with the filtered total: a compact content card, tinted
    /// with the type's colour while it is the active type filter.
    private func summaryCellView(label: String, amount: Int64, color: Color, icon: String, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Label(label, systemImage: icon)
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(appViewModel.currencyManager.formatAmount(amount.displayAmount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                isActive ? AnyShapeStyle(color.opacity(0.15)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: CardStyle.Size.compact.cornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Category filter (B6)

/// Category-chip matching for the Transactions filter. A chip stands for a
/// normalised name + type (the key `DataStore.displayCategories` dedups by,
/// and the grouping Reports uses), so on a shared account a member's
/// «Продукты» chip also matches the partner's «Продукты» row whose category
/// has a different id — both members see the same list and totals.
struct TransactionCategoryFilter {
    let selectedIds: Set<String>
    let selectedKeys: Set<String>

    init(selectedIds: Set<String>, categories: [Category]) {
        self.selectedIds = selectedIds
        var keys: Set<String> = []
        if !selectedIds.isEmpty {
            for cat in categories where selectedIds.contains(cat.id) {
                keys.insert(Self.key(for: cat))
            }
        }
        self.selectedKeys = keys
    }

    /// Same normalisation as `DataStore.displayCategories`.
    static func key(for category: Category) -> String {
        "\(category.name.lowercased().trimmingCharacters(in: .whitespaces))_\(category.type.rawValue)"
    }

    var isActive: Bool { !selectedIds.isEmpty }

    /// With chips selected, a row passes only when its category matches one
    /// (uncategorised rows and transfers used to slip through every
    /// category filter). `category` is the row's resolved category; when
    /// RLS / an inactive category leaves it unresolved the id still counts.
    func matches(_ tx: Transaction, category: Category?) -> Bool {
        guard isActive else { return true }
        if let category, selectedKeys.contains(Self.key(for: category)) { return true }
        if let id = tx.categoryId, selectedIds.contains(id) { return true }
        return false
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
    let categories: [Category]
    @Binding var selectedAccountIds: Set<String>
    @Binding var selectedCategoryIds: Set<String>
    @Binding var dateFrom: Date?
    @Binding var dateTo: Date?
    @Binding var selectedType: TransactionTypeFilter

    @State private var selectedPeriod: FilterPeriod = .all
    @State private var calendarFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var calendarTo = Date()

    /// Period presets; `custom` is the from–to calendar range.
    enum FilterPeriod: CaseIterable {
        case all, today, week, month, custom

        var label: String {
            switch self {
            case .all: String(localized: "common.all")
            case .today: String(localized: "filter.today")
            case .week: String(localized: "filter.week")
            case .month: String(localized: "filter.month")
            case .custom: String(localized: "period.customRange")
            }
        }

        /// The `dateFrom` / `dateTo` the period applies (`nil` = open end).
        /// Presets end now; `custom` takes the calendar pickers' values.
        func dateRange(
            now: Date = Date(),
            calendar: Calendar = .current,
            customFrom: Date,
            customTo: Date
        ) -> (from: Date?, to: Date?) {
            switch self {
            case .all: (nil, nil)
            case .today: (calendar.startOfDay(for: now), now)
            case .week: (calendar.date(byAdding: .day, value: -7, to: now), now)
            case .month: (calendar.date(byAdding: .month, value: -1, to: now), now)
            case .custom: (customFrom, customTo)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Type filter
                Section(String(localized: "transactions.filterType")) {
                    Picker(String(localized: "transactions.filterType"), selection: $selectedType) {
                        ForEach(TransactionTypeFilter.allCases, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Period filter
                Section(String(localized: "transactions.filterPeriod")) {
                    Picker(String(localized: "transactions.filterPeriod"), selection: $selectedPeriod) {
                        ForEach(FilterPeriod.allCases, id: \.self) { period in
                            if period == .custom {
                                Label(period.label, systemImage: "calendar")
                                    .labelStyle(.iconOnly)
                                    .tag(period)
                            } else {
                                Text(period.label).tag(period)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if selectedPeriod == .custom {
                        DatePicker(String(localized: "filter.from"), selection: $calendarFrom, displayedComponents: .date)
                        DatePicker(String(localized: "filter.to"), selection: $calendarTo, displayedComponents: .date)
                    }
                }

                // Category filter (multi-select)
                Section(String(localized: "transactions.filterCategory")) {
                    chipRow {
                        TransactionFilterChip(
                            label: String(localized: "common.all"),
                            isSelected: selectedCategoryIds.isEmpty
                        ) {
                            selectedCategoryIds.removeAll()
                        }

                        ForEach(categories) { cat in
                            TransactionFilterChip(
                                icon: cat.icon,
                                label: cat.name,
                                isSelected: selectedCategoryIds.contains(cat.id)
                            ) {
                                if selectedCategoryIds.contains(cat.id) {
                                    selectedCategoryIds.remove(cat.id)
                                } else {
                                    selectedCategoryIds.insert(cat.id)
                                }
                            }
                        }
                    }
                }

                // Account filter (multi-select)
                Section(String(localized: "transactions.filterAccount")) {
                    chipRow {
                        TransactionFilterChip(
                            label: String(localized: "budget.allAccounts"),
                            isSelected: selectedAccountIds.isEmpty
                        ) {
                            selectedAccountIds.removeAll()
                        }

                        ForEach(accounts) { account in
                            TransactionFilterChip(
                                icon: account.icon,
                                label: account.name,
                                isSelected: selectedAccountIds.contains(account.id)
                            ) {
                                if selectedAccountIds.contains(account.id) {
                                    selectedAccountIds.remove(account.id)
                                } else {
                                    selectedAccountIds.insert(account.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "transactions.filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Type, category and account apply as they're tapped (as
                // before); the period applies with «Применить».
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.apply")) {
                        applyFilters()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if dateFrom != nil {
                selectedPeriod = .custom
                calendarFrom = dateFrom ?? Date()
                calendarTo = dateTo ?? Date()
            }
        }
    }

    /// Horizontally scrolling chips, edge to edge inside the form row.
    private func chipRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .listRowInsets(EdgeInsets())
    }

    private func applyFilters() {
        let range = selectedPeriod.dateRange(customFrom: calendarFrom, customTo: calendarTo)
        dateFrom = range.from
        dateTo = range.to
    }
}

/// Multi-select chip of the filter sheet: a system bordered capsule,
/// prominent while selected.
private struct TransactionFilterChip: View {
    var icon: String?
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Text(icon)
                }
                Text(label)
            }
            .font(.subheadline.weight(.medium))
        }
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered).tint(.secondary)
        }
    }
}
