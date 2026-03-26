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

    private var dataStore: DataStore { appViewModel.dataStore }

    private var displayedTransactions: [Transaction] {
        var result = viewModel.filteredTransactions(from: dataStore.transactions)
        if let accountId = filterAccountId {
            result = result.filter { $0.accountId == accountId }
        }
        if let from = filterDateFrom {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            result = result.filter {
                guard let d = df.date(from: $0.date) else { return true }
                return d >= from
            }
        }
        if let to = filterDateTo {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            result = result.filter {
                guard let d = df.date(from: $0.date) else { return true }
                return d <= to
            }
        }
        return result
    }

    private var hasActiveFilters: Bool {
        filterAccountId != nil || filterDateFrom != nil || filterDateTo != nil
    }

    var body: some View {
        @Bindable var vm = viewModel
        NavigationStack {
            List {
                if hasActiveFilters {
                    Section {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .foregroundStyle(.green)
                            Text("Фильтры активны")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Сбросить") {
                                filterAccountId = nil
                                filterDateFrom = nil
                                filterDateTo = nil
                            }
                            .font(.caption)
                        }
                    }
                }

                ForEach(displayedTransactions) { transaction in
                    TransactionRowView(
                        transaction: transaction,
                        category: dataStore.category(for: transaction)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingTransaction = transaction
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await dataStore.deleteTransaction(transaction) }
                        } label: {
                            Label("Удалить", systemImage: "trash")
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
            }
            .listStyle(.plain)
            .searchable(text: $vm.searchText, prompt: "Поиск операций")
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showAddTransaction = true
                        } label: {
                            Label("Доход / Расход", systemImage: "plus")
                        }
                        Button {
                            showTransfer = true
                        } label: {
                            Label("Перевод", systemImage: "arrow.left.arrow.right")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Добавить операцию")
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
                    dateTo: $filterDateTo
                )
                .presentationDetents([.medium])
            }
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

    @State private var useDateFilter = false
    @State private var localFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var localTo = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Счёт") {
                    Picker("Счёт", selection: $selectedAccountId) {
                        Text("Все счета").tag(nil as String?)
                        ForEach(accounts) { account in
                            Text("\(account.icon) \(account.name)").tag(account.id as String?)
                        }
                    }
                }

                Section("Период") {
                    Toggle("Фильтр по дате", isOn: $useDateFilter)
                    if useDateFilter {
                        DatePicker("От", selection: $localFrom, displayedComponents: .date)
                        DatePicker("До", selection: $localTo, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Применить") {
                        dateFrom = useDateFilter ? localFrom : nil
                        dateTo = useDateFilter ? localTo : nil
                        dismiss()
                    }
                }
            }
            .onAppear {
                useDateFilter = dateFrom != nil
                if let d = dateFrom { localFrom = d }
                if let d = dateTo { localTo = d }
            }
        }
    }
}
