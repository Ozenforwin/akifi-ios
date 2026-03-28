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
        var result = viewModel.filteredTransactions(from: dataStore.transactions)

        // Type filter
        switch filterType {
        case .all: break
        case .expense: result = result.filter { $0.type == .expense && !$0.isTransfer }
        case .income: result = result.filter { $0.type == .income && !$0.isTransfer }
        case .transfer: result = result.filter { $0.isTransfer }
        }

        // Account filter
        if let accountId = filterAccountId {
            result = result.filter { $0.accountId == accountId }
        }

        // Date filter
        let df = Self.isoDF
        if let from = filterDateFrom {
            result = result.filter {
                guard let d = df.date(from: $0.date) else { return true }
                return d >= Calendar.current.startOfDay(for: from)
            }
        }
        if let to = filterDateTo {
            result = result.filter {
                guard let d = df.date(from: $0.date) else { return true }
                return d <= Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to))!
            }
        }
        return result
    }

    private var hasActiveFilters: Bool {
        filterAccountId != nil || filterDateFrom != nil || filterDateTo != nil || filterType != .all
    }

    var body: some View {
        @Bindable var vm = viewModel
        NavigationStack {
            List {
                if hasActiveFilters {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(Color.accent)
                        Text("Фильтры активны")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Сбросить") {
                            filterAccountId = nil
                            filterDateFrom = nil
                            filterDateTo = nil
                            filterType = .all
                        }
                        .font(.caption)
                    }
                    .listRowSeparator(.hidden)
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
                            Label("Удалить", systemImage: "trash.fill")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingTransaction = transaction
                        } label: {
                            Label("Изменить", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }

                // Bottom spacer for tab bar
                Color.clear.frame(height: 80)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle("Операции")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Фильтры")
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
}

// MARK: - Transaction Type Filter

enum TransactionTypeFilter: String, CaseIterable {
    case all = "Все"
    case expense = "Расходы"
    case income = "Доходы"
    case transfer = "Переводы"

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

    enum FilterPeriod: String, CaseIterable {
        case all = "Все"
        case today = "Сегодня"
        case week = "Неделя"
        case month = "Месяц"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Фильтры")
                        .font(.title2.weight(.bold))
                        .padding(.horizontal)

                    // Type filter
                    filterSection(title: "ТИП") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TransactionTypeFilter.allCases, id: \.self) { type in
                                    filterChip(
                                        label: type.rawValue,
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
                    filterSection(title: "ПЕРИОД") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                            ForEach(FilterPeriod.allCases, id: \.self) { period in
                                filterChip(
                                    label: period.rawValue,
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
                            DatePicker("С", selection: $calendarFrom, displayedComponents: .date)
                                .datePickerStyle(.compact)
                            DatePicker("По", selection: $calendarTo, displayedComponents: .date)
                                .datePickerStyle(.compact)
                        }
                        .padding(.horizontal)
                    }

                    // Account filter
                    filterSection(title: "СЧЁТ") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterChip(
                                    label: "Все счета",
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
                    Text("Применить")
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
