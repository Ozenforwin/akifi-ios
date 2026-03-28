import SwiftUI

struct TransferFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let accounts: [Account]
    let onSave: () async -> Void

    @State private var calculatorState = CalculatorState()
    @State private var fromAccountId: String?
    @State private var toAccountId: String?
    @State private var date = Date()
    @State private var description = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let transactionRepo = TransactionRepository()

    private var isValid: Bool {
        guard let amount = calculatorState.getResult(), amount > 0 else { return false }
        return fromAccountId != nil &&
               toAccountId != nil &&
               fromAccountId != toAccountId
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сумма") {
                    CalculatorKeyboardView(state: calculatorState)
                }

                Section("Откуда") {
                    ForEach(accounts) { account in
                        Button {
                            fromAccountId = account.id
                        } label: {
                            HStack {
                                Text(account.icon)
                                    .font(.title3)
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(appViewModel.currencyManager.formatAmount(
                                    appViewModel.dataStore.balance(for: account).displayAmount
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if fromAccountId == account.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(toAccountId == account.id)
                    }
                }

                Section("Куда") {
                    ForEach(accounts) { account in
                        Button {
                            toAccountId = account.id
                        } label: {
                            HStack {
                                Text(account.icon)
                                    .font(.title3)
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if toAccountId == account.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(fromAccountId == account.id)
                    }
                }

                Section("Детали") {
                    TextField("Комментарий", text: $description)
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
            .navigationTitle("Перевод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Перевести") {
                        Task { await save() }
                    }
                    .disabled(!isValid || isLoading)
                }
            }
        }
    }

    private func save() async {
        guard let amountValue = calculatorState.getResult(),
              amountValue > 0,
              let fromId = fromAccountId,
              let toId = toAccountId else {
            errorMessage = "Заполните все поля"
            return
        }

        isLoading = true
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: date)
        let desc = description.isEmpty ? "Перевод" : description

        do {
            // Expense from source
            _ = try await transactionRepo.create(CreateTransactionInput(
                account_id: fromId,
                amount: amountValue,
                type: TransactionType.transfer.rawValue,
                date: dateStr,
                description: desc,
                category_id: nil,
                merchant_name: nil
            ))
            // Income to destination
            _ = try await transactionRepo.create(CreateTransactionInput(
                account_id: toId,
                amount: amountValue,
                type: TransactionType.transfer.rawValue,
                date: dateStr,
                description: desc,
                category_id: nil,
                merchant_name: nil
            ))
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
