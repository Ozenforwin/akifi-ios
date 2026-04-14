import SwiftUI

struct TransferFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let accounts: [Account]
    let editingTransaction: Transaction?
    let onSave: () async -> Void

    @State private var calculatorState = CalculatorState()
    @State private var fromAccountId: String?
    @State private var toAccountId: String?
    @State private var date = Date()
    @State private var description = ""
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isEditing: Bool { editingTransaction != nil }

    init(accounts: [Account], editingTransaction: Transaction? = nil, onSave: @escaping () async -> Void) {
        self.accounts = accounts
        self.editingTransaction = editingTransaction
        self.onSave = onSave
    }

    private var isValid: Bool {
        guard let amount = calculatorState.getResult(), amount > 0 else { return false }
        return fromAccountId != nil &&
               toAccountId != nil &&
               fromAccountId != toAccountId
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "transfer.amount")) {
                    CalculatorKeyboardView(state: calculatorState)
                }

                Section(String(localized: "transfer.from")) {
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

                Section(String(localized: "transfer.to")) {
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

                Section(String(localized: "transfer.details")) {
                    TextField(String(localized: "transfer.comment"), text: $description)
                    DatePicker(String(localized: "common.date"), selection: $date, displayedComponents: .date)
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
            .navigationTitle(isEditing ? String(localized: "common.editing") : String(localized: "transaction.transfer"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                prefillIfEditing()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "common.update") : String(localized: "transfer.submit")) {
                        Task { await save() }
                    }
                    .disabled(!isValid || isLoading)
                }
            }
        }
    }

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

    private func prefillIfEditing() {
        guard let tx = editingTransaction else {
            selectedCurrency = appViewModel.currencyManager.selectedCurrency
            return
        }

        let cm = appViewModel.currencyManager
        let dataStore = appViewModel.dataStore

        // Amount
        if let cur = tx.currency, let code = CurrencyCode(rawValue: cur.uppercased()) {
            selectedCurrency = code
            let displayAmount = cm.convertToAccountCurrency(tx.amount.displayAmount, accountCurrency: code)
            calculatorState.setValue(abs(displayAmount))
        } else {
            selectedCurrency = cm.selectedCurrency
            let displayAmount = cm.convertToAccountCurrency(tx.amount.displayAmount, accountCurrency: cm.selectedCurrency)
            calculatorState.setValue(abs(displayAmount))
        }

        description = tx.description ?? ""

        // Parse date
        if let txDate = Self.isoDateTimeFormatter.date(from: tx.rawDateTime) ?? Self.isoDateFormatter.date(from: tx.date) {
            date = txDate
        }

        // Determine from/to accounts using the transfer pair
        if let groupId = tx.transferGroupId,
           let pair = dataStore.transactions.first(where: { $0.transferGroupId == groupId && $0.id != tx.id }) {
            // The expense side is "from", the income side is "to"
            if tx.amount < 0 {
                fromAccountId = tx.accountId
                toAccountId = pair.accountId
            } else {
                fromAccountId = pair.accountId
                toAccountId = tx.accountId
            }
        } else {
            // Pair not found — use current transaction's account
            if tx.amount < 0 {
                fromAccountId = tx.accountId
            } else {
                toAccountId = tx.accountId
            }
        }
    }

    private func save() async {
        guard let amountValue = calculatorState.getResult(),
              amountValue > 0,
              let fromId = fromAccountId,
              let toId = toAccountId else {
            errorMessage = String(localized: "transfer.fillAllFields")
            return
        }

        isLoading = true
        let dateStr = AppDateFormatters.isoDate.string(from: date)
        let desc = description.isEmpty ? nil : description

        // Convert entered amount from selected currency to base currency
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
            let dataStore = appViewModel.dataStore

            if let tx = editingTransaction, let groupId = tx.transferGroupId {
                // Editing: update both sides of the transfer
                let pair = dataStore.transactions.first { $0.transferGroupId == groupId && $0.id != tx.id }

                // Determine which is expense (from) and which is income (to)
                let expenseTxId: String
                let incomeTxId: String?
                if tx.amount < 0 {
                    expenseTxId = tx.id
                    incomeTxId = pair?.id
                } else {
                    expenseTxId = pair?.id ?? tx.id
                    incomeTxId = pair != nil ? tx.id : nil
                }

                // Update expense side (from)
                try await dataStore.updateTransaction(id: expenseTxId, UpdateTransactionInput(
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    date: dateStr,
                    description: desc,
                    account_id: fromId
                ))

                // Update income side (to) if it exists
                if let incomeId = incomeTxId {
                    try await dataStore.updateTransaction(id: incomeId, UpdateTransactionInput(
                        amount: amountInBase,
                        currency: selectedCurrency.rawValue,
                        date: dateStr,
                        description: desc,
                        account_id: toId
                    ))
                }
            } else {
                // Creating new transfer
                let groupId = UUID().uuidString

                // Source: expense (money leaves this account)
                _ = try await dataStore.addTransaction(CreateTransactionInput(
                    user_id: userId,
                    account_id: fromId,
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    type: TransactionType.expense.rawValue,
                    date: dateStr,
                    description: desc,
                    category_id: nil,
                    merchant_name: nil,
                    transfer_group_id: groupId
                ))
                // Destination: income (money arrives to this account)
                _ = try await dataStore.addTransaction(CreateTransactionInput(
                    user_id: userId,
                    account_id: toId,
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    type: TransactionType.income.rawValue,
                    date: dateStr,
                    description: desc,
                    category_id: nil,
                    merchant_name: nil,
                    transfer_group_id: groupId
                ))
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
