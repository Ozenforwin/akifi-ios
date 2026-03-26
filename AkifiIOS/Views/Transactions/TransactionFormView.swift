import SwiftUI

struct TransactionFormView: View {
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let accounts: [Account]
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

    private var filteredCategories: [Category] {
        categories.filter { $0.type.rawValue == selectedType.rawValue || selectedType == .transfer }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Type picker
                Section {
                    Picker("Тип", selection: $selectedType) {
                        Text("Расход").tag(TransactionType.expense)
                        Text("Доход").tag(TransactionType.income)
                    }
                    .pickerStyle(.segmented)
                }

                // Amount
                Section("Сумма") {
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.title2)
                }

                // Category
                Section("Категория") {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 70))
                    ], spacing: 12) {
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

                // Account
                if !accounts.isEmpty {
                    Section("Счет") {
                        Picker("Счет", selection: $selectedAccountId) {
                            Text("Без счета").tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }

                // Details
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
            .navigationTitle("Новая операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task { await save() }
                    }
                    .disabled(amount.isEmpty || isLoading)
                }
            }
        }
    }

    private func save() async {
        guard let amountValue = Double(amount.replacingOccurrences(of: ",", with: ".")) else {
            errorMessage = "Некорректная сумма"
            return
        }

        isLoading = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let input = CreateTransactionInput(
            account_id: selectedAccountId,
            amount: Int64(amountValue * 100),
            tx_type: selectedType.rawValue,
            date: formatter.string(from: date),
            description: description.isEmpty ? nil : description,
            category_id: selectedCategoryId,
            merchant: nil
        )

        do {
            _ = try await transactionRepo.create(input)
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
    }
}
