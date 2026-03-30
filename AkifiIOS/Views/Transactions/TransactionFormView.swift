import SwiftUI

struct TransactionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    let categories: [Category]
    let accounts: [Account]
    let editingTransaction: Transaction?
    let onSave: () async -> Void

    @State private var calculatorState = CalculatorState()
    @State private var description = ""
    @State private var selectedType: TransactionType = .expense
    @State private var selectedCategoryId: String?
    @State private var selectedAccountId: String?
    @State private var date = Date()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCategoryPicker = false
    @State private var showCalculator = true
    @State private var selectedCurrency: CurrencyCode = .rub

    private let transactionRepo = TransactionRepository()
    private static let isoDateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df
    }()
    private static let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var isEditing: Bool { editingTransaction != nil }

    init(categories: [Category], accounts: [Account], editingTransaction: Transaction? = nil, defaultType: TransactionType? = nil, onSave: @escaping () async -> Void) {
        self.categories = categories
        self.accounts = accounts
        self.editingTransaction = editingTransaction
        self.onSave = onSave
        if let defaultType, editingTransaction == nil {
            _selectedType = State(initialValue: defaultType)
        }
    }

    private var filteredCategories: [Category] {
        categories.filter { $0.type.rawValue == selectedType.rawValue || selectedType == .transfer }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "common.type"), selection: $selectedType) {
                        Text(String(localized: "common.expense")).tag(TransactionType.expense)
                        Text(String(localized: "common.income")).tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "common.amount")) {
                    CalculatorKeyboardView(state: calculatorState)
                }

                Section(String(localized: "common.category")) {
                    if filteredCategories.count > 8 {
                        Button {
                            showCategoryPicker = true
                        } label: {
                            HStack {
                                if let catId = selectedCategoryId,
                                   let cat = filteredCategories.first(where: { $0.id == catId }) {
                                    Text(cat.icon)
                                    Text(cat.name)
                                        .foregroundStyle(.primary)
                                } else {
                                    Text(String(localized: "transaction.selectCategory"))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 12) {
                            ForEach(filteredCategories) { category in
                                CategoryChip(
                                    category: category,
                                    isSelected: selectedCategoryId == category.id
                                ) {
                                    selectedCategoryId = category.id
                                }
                            }
                        }
                    }
                }

                if !accounts.isEmpty {
                    Section(String(localized: "common.account")) {
                        Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                            Text(String(localized: "transaction.noAccount")).tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }

                Section(String(localized: "transaction.details")) {
                    TextField(String(localized: "transaction.description"), text: $description)
                    DatePicker(String(localized: "transaction.dateTime"), selection: $date, displayedComponents: [.date, .hourAndMinute])
                    Picker(String(localized: "common.currency"), selection: $selectedCurrency) {
                        ForEach(CurrencyCode.allCases, id: \.self) { currency in
                            Text("\(currency.symbol) \(currency.name)").tag(currency)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "common.editing") : String(localized: "transaction.newTransaction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "common.update") : String(localized: "common.save")) {
                        Task { await save() }
                    }
                    .disabled(calculatorState.getResult() == nil || isLoading)
                }
            }
            .onAppear { prefillIfEditing() }
            .sheet(isPresented: $showCategoryPicker) {
                CategoryPickerView(
                    categories: categories,
                    transactionType: selectedType,
                    selectedCategoryId: $selectedCategoryId
                )
                .presentationDetents([.medium])
            }
        }
    }

    private func prefillIfEditing() {
        guard let tx = editingTransaction else {
            // New transaction: default to the user's selected display currency
            selectedCurrency = appViewModel.currencyManager.selectedCurrency
            return
        }
        calculatorState.setValue(tx.amount.displayAmount)
        description = tx.description ?? ""
        selectedType = tx.type
        selectedCategoryId = tx.categoryId
        selectedAccountId = tx.accountId
        if let cur = tx.currency, let code = CurrencyCode(rawValue: cur.uppercased()) {
            selectedCurrency = code
        } else {
            selectedCurrency = appViewModel.currencyManager.selectedCurrency
        }
        if let txDate = Self.isoDateTimeFormatter.date(from: tx.rawDateTime) ?? Self.isoDateFormatter.date(from: tx.date) {
            date = txDate
        }
    }

    private func save() async {
        guard let amountValue = calculatorState.getResult(), amountValue > 0 else {
            errorMessage = String(localized: "transaction.invalidAmount")
            return
        }

        isLoading = true
        let dateStr = Self.isoDateTimeFormatter.string(from: date)

        do {
            if let tx = editingTransaction {
                let input = UpdateTransactionInput(
                    amount: amountValue,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil,
                    currency: selectedCurrency.rawValue
                )
                try await transactionRepo.update(id: tx.id, input)
            } else {
                let input = CreateTransactionInput(
                    account_id: selectedAccountId,
                    amount: amountValue,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil,
                )
                _ = try await transactionRepo.create(input)
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct CategoryChip: View {
    let category: Category
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(category.icon)
                    .font(.title2)
                Text(category.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 70, height: 70)
            .background(isSelected ? Color(hex: category.color).opacity(0.2) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color(hex: category.color) : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.name), \(isSelected ? "выбрано" : "")")
    }
}
