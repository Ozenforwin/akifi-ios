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
                                .foregroundStyle(Color.accent)
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

    @State private var selectedPeriod: FilterPeriod = .all
    @State private var useDateFilter = false
    @State private var localFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var localTo = Date()

    enum FilterPeriod: String, CaseIterable {
        case all = "Все"
        case today = "Сегодня"
        case week = "Неделя"
        case month = "Месяц"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Фильтры")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal)

                // Period
                VStack(alignment: .leading, spacing: 8) {
                    Text("ПЕРИОД")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilterPeriod.allCases, id: \.self) { period in
                                Button {
                                    selectedPeriod = period
                                } label: {
                                    Text(period.rawValue)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(selectedPeriod == period ? Color.accent : Color(.secondarySystemBackground))
                                        .foregroundStyle(selectedPeriod == period ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Account
                VStack(alignment: .leading, spacing: 8) {
                    Text("СЧЁТ")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                selectedAccountId = nil
                            } label: {
                                Text("Все счета")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedAccountId == nil ? Color.accent : Color(.secondarySystemBackground))
                                    .foregroundStyle(selectedAccountId == nil ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            ForEach(accounts) { account in
                                Button {
                                    selectedAccountId = account.id
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(account.icon)
                                            .font(.caption)
                                        Text(account.name)
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedAccountId == account.id ? Color.accent : Color(.secondarySystemBackground))
                                    .foregroundStyle(selectedAccountId == account.id ? .white : .primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Spacer()

                // Apply button
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
            .padding(.top, 20)
            .onAppear {
                useDateFilter = dateFrom != nil
                if let d = dateFrom { localFrom = d }
                if let d = dateTo { localTo = d }
            }
        }
    }

    private func applyFilters() {
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
