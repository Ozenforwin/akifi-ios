import SwiftUI

struct TransactionFormView: View {
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let accounts: [Account]
    let editingTransaction: Transaction?
    let onSave: () async -> Void

    @State private var amount = ""
    @State private var description = ""
    @State private var selectedType: TransactionType = .expense
    @State private var selectedCategoryId: String?
    @State private var selectedAccountId: String?
    @State private var date = Date()
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let transactionRepo = TransactionRepository()
    private let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var isEditing: Bool { editingTransaction != nil }

    init(categories: [Category], accounts: [Account], editingTransaction: Transaction? = nil, onSave: @escaping () async -> Void) {
        self.categories = categories
        self.accounts = accounts
        self.editingTransaction = editingTransaction
        self.onSave = onSave
    }

    private var filteredCategories: [Category] {
        categories.filter { $0.type.rawValue == selectedType.rawValue || selectedType == .transfer }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Тип", selection: $selectedType) {
                        Text("Расход").tag(TransactionType.expense)
                        Text("Доход").tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Сумма") {
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.title2)
                }

                Section("Категория") {
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

                if !accounts.isEmpty {
                    Section("Счёт") {
                        Picker("Счёт", selection: $selectedAccountId) {
                            Text("Без счёта").tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }

                Section("Детали") {
                    TextField("Описание", text: $description)
                    DatePicker("Дата", selection: $date, displayedComponents: .date)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Редактирование" : "Новая операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Обновить" : "Сохранить") {
                        Task { await save() }
                    }
                    .disabled(amount.isEmpty || isLoading)
                }
            }
            .onAppear { prefillIfEditing() }
        }
    }

    private func prefillIfEditing() {
        guard let tx = editingTransaction else { return }
        amount = "\(tx.amount.displayAmount)"
        description = tx.description ?? ""
        selectedType = tx.type
        selectedCategoryId = tx.categoryId
        selectedAccountId = tx.accountId
        if let txDate = isoDateFormatter.date(from: tx.date) {
            date = txDate
        }
    }

    private func save() async {
        guard let amountValue = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")) else {
            errorMessage = "Некорректная сумма"
            return
        }

        isLoading = true
        let amountCents = Int64(truncating: (amountValue * 100) as NSDecimalNumber)
        let dateStr = isoDateFormatter.string(from: date)

        do {
            if let tx = editingTransaction {
                let input = UpdateTransactionInput(
                    amount: amountCents,
                    tx_type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant: nil
                )
                try await transactionRepo.update(id: tx.id, input)
            } else {
                let input = CreateTransactionInput(
                    account_id: selectedAccountId,
                    amount: amountCents,
                    tx_type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant: nil
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
