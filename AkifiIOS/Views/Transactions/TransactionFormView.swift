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

    init(categories: [Category], accounts: [Account], editingTransaction: Transaction? = nil, defaultType: TransactionType? = nil, defaultCategoryId: String? = nil, onSave: @escaping () async -> Void) {
        self.categories = categories
        self.accounts = accounts
        self.editingTransaction = editingTransaction
        self.onSave = onSave
        if let defaultType, editingTransaction == nil {
            _selectedType = State(initialValue: defaultType)
        }
        if let defaultCategoryId, editingTransaction == nil {
            _selectedCategoryId = State(initialValue: defaultCategoryId)
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
            selectedCurrency = appViewModel.currencyManager.selectedCurrency
            return
        }

        // Amount is stored in base currency (RUB) — convert to the tx currency for display
        let cm = appViewModel.currencyManager
        if let cur = tx.currency, let code = CurrencyCode(rawValue: cur.uppercased()) {
            selectedCurrency = code
            // Convert from base (RUB) to the transaction's currency for editing
            let displayAmount = cm.convertToAccountCurrency(tx.amount.displayAmount, accountCurrency: code)
            calculatorState.setValue(displayAmount)
        } else {
            selectedCurrency = cm.selectedCurrency
            let displayAmount = cm.convertToAccountCurrency(tx.amount.displayAmount, accountCurrency: cm.selectedCurrency)
            calculatorState.setValue(displayAmount)
        }

        description = tx.description ?? ""
        selectedType = tx.type
        selectedCategoryId = tx.categoryId
        selectedAccountId = tx.accountId
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

        // Convert entered amount from selected currency to base currency (RUB)
        let cm = appViewModel.currencyManager
        let amountInBase: Decimal
        if selectedCurrency == cm.dataCurrency {
            amountInBase = amountValue
        } else {
            amountInBase = cm.convertFromAccountCurrency(amountValue, accountCurrency: selectedCurrency)
        }

        do {
            // Always source user_id from the live Supabase session.
            // `dataStore.profile?.id` can be stale right after sign-in or
            // token refresh, and mismatch → RLS violation on INSERT.
            let userId = try await SupabaseManager.shared.currentUserId()
            if let tx = editingTransaction {
                let input = UpdateTransactionInput(
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil
                )
                try await appViewModel.dataStore.updateTransaction(id: tx.id, input)
            } else {
                let input = CreateTransactionInput(
                    user_id: userId,
                    account_id: selectedAccountId,
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil
                )
                _ = try await appViewModel.dataStore.addTransaction(input)
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
