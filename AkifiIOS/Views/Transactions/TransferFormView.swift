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

        description = tx.description ?? ""

        if let txDate = Self.isoDateTimeFormatter.date(from: tx.rawDateTime) ?? Self.isoDateFormatter.date(from: tx.date) {
            date = txDate
        }

        // Resolve the transfer pair. Source = expense leg, destination = income leg.
        let pair: Transaction?
        if let groupId = tx.transferGroupId {
            pair = dataStore.transactions.first { $0.transferGroupId == groupId && $0.id != tx.id }
        } else {
            pair = nil
        }
        let sourceLeg: Transaction
        let destLeg: Transaction?
        if tx.type == .expense || tx.amountNative < 0 {
            sourceLeg = tx
            destLeg = pair
            fromAccountId = tx.accountId
            toAccountId = pair?.accountId
        } else {
            sourceLeg = pair ?? tx
            destLeg = pair == nil ? nil : tx
            fromAccountId = pair?.accountId ?? tx.accountId
            toAccountId = tx.accountId
        }

        // Recover the user's original entry. If a leg has `foreignAmount`/
        // `foreignCurrency`, that's the user's input verbatim. Otherwise the
        // entry was in the source account's currency — derive from
        // `sourceLeg.amountNative` + that account's currency.
        let entryLeg = (sourceLeg.foreignAmount != nil ? sourceLeg : (destLeg?.foreignAmount != nil ? destLeg : nil)) ?? sourceLeg
        if let foreign = entryLeg.foreignAmount,
           let foreignCur = entryLeg.foreignCurrency,
           let code = CurrencyCode(rawValue: foreignCur.uppercased()) {
            selectedCurrency = code
            calculatorState.setValue(abs(foreign))
        } else {
            // Fall back to the source leg's account currency.
            let srcAccount = dataStore.accounts.first { $0.id == sourceLeg.accountId }
            let srcCode = srcAccount?.currencyCode ?? cm.dataCurrency
            selectedCurrency = srcCode
            calculatorState.setValue(abs(sourceLeg.amountNative.displayAmount))
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

        // ADR-001: each leg of the transfer must be stored in its OWN
        // account's currency. Cross-currency entry currency lives in
        // `foreign_*`. Using a single base-currency value for both legs
        // (the prior behavior) wrote 39 747 RUB into a USD leg which
        // the read-path then summed as USD, sending the destination
        // balance ~75× too far in the wrong direction.
        let cm = appViewModel.currencyManager
        let dataStore = appViewModel.dataStore
        guard let fromAccount = accounts.first(where: { $0.id == fromId }),
              let toAccount = accounts.first(where: { $0.id == toId }) else {
            errorMessage = String(localized: "transfer.fillAllFields")
            isLoading = false
            return
        }

        let fromLeg = Self.legFields(amountValue: amountValue, entryCurrency: selectedCurrency, account: fromAccount, cm: cm)
        let toLeg = Self.legFields(amountValue: amountValue, entryCurrency: selectedCurrency, account: toAccount, cm: cm)

        do {
            // Always source user_id from the live Supabase session.
            // `dataStore.profile?.id` can be stale right after sign-in or
            // token refresh, and mismatch → RLS violation on INSERT.
            let userId = try await SupabaseManager.shared.currentUserId()

            if let tx = editingTransaction, let groupId = tx.transferGroupId {
                // Editing: update both sides of the transfer
                let pair = dataStore.transactions.first { $0.transferGroupId == groupId && $0.id != tx.id }

                let expenseTxId: String
                let incomeTxId: String?
                if tx.type == .expense || tx.amountNative < 0 {
                    expenseTxId = tx.id
                    incomeTxId = pair?.id
                } else {
                    expenseTxId = pair?.id ?? tx.id
                    incomeTxId = pair != nil ? tx.id : nil
                }

                try await dataStore.updateTransaction(id: expenseTxId, UpdateTransactionInput(
                    amount: fromLeg.amountInAccount,
                    amount_native: fromLeg.amountInAccount,
                    currency: fromLeg.currencyLabel,
                    foreign_amount: fromLeg.foreignAmount,
                    foreign_currency: fromLeg.foreignCurrency,
                    fx_rate: fromLeg.fxRate,
                    date: dateStr,
                    description: desc,
                    account_id: fromId,
                    replaceCurrencyFields: true
                ))

                if let incomeId = incomeTxId {
                    try await dataStore.updateTransaction(id: incomeId, UpdateTransactionInput(
                        amount: toLeg.amountInAccount,
                        amount_native: toLeg.amountInAccount,
                        currency: toLeg.currencyLabel,
                        foreign_amount: toLeg.foreignAmount,
                        foreign_currency: toLeg.foreignCurrency,
                        fx_rate: toLeg.fxRate,
                        date: dateStr,
                        description: desc,
                        account_id: toId,
                        replaceCurrencyFields: true
                    ))
                }
            } else {
                // Creating new transfer
                let groupId = UUID().uuidString

                _ = try await dataStore.addTransaction(CreateTransactionInput(
                    user_id: userId,
                    account_id: fromId,
                    amount: fromLeg.amountInAccount,
                    amount_native: fromLeg.amountInAccount,
                    currency: fromLeg.currencyLabel,
                    foreign_amount: fromLeg.foreignAmount,
                    foreign_currency: fromLeg.foreignCurrency,
                    fx_rate: fromLeg.fxRate,
                    type: TransactionType.expense.rawValue,
                    date: dateStr,
                    description: desc,
                    category_id: nil,
                    merchant_name: nil,
                    transfer_group_id: groupId
                ))
                _ = try await dataStore.addTransaction(CreateTransactionInput(
                    user_id: userId,
                    account_id: toId,
                    amount: toLeg.amountInAccount,
                    amount_native: toLeg.amountInAccount,
                    currency: toLeg.currencyLabel,
                    foreign_amount: toLeg.foreignAmount,
                    foreign_currency: toLeg.foreignCurrency,
                    fx_rate: toLeg.fxRate,
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

    /// Per-leg amount + foreign-currency fields, derived from the user's
    /// entry (amountValue in entryCurrency) projected onto a single account.
    /// `foreign_*` is set only when entryCurrency ≠ account.currency.
    struct LegFields: Equatable {
        let amountInAccount: Decimal
        let currencyLabel: String
        let foreignAmount: Decimal?
        let foreignCurrency: String?
        let fxRate: Decimal?
    }

    static func legFields(amountValue: Decimal, entryCurrency: CurrencyCode, account: Account, cm: CurrencyManager) -> LegFields {
        let accountCode = account.currencyCode
        let currencyLabel = accountCode.rawValue
        if entryCurrency == accountCode {
            return LegFields(
                amountInAccount: amountValue,
                currencyLabel: currencyLabel,
                foreignAmount: nil,
                foreignCurrency: nil,
                fxRate: nil
            )
        }
        let amountInAccount = crossConvert(amount: amountValue, from: entryCurrency, to: accountCode, using: cm)
        let fxRate: Decimal? = amountValue != 0 ? (amountInAccount / amountValue) : nil
        return LegFields(
            amountInAccount: amountInAccount,
            currencyLabel: currencyLabel,
            foreignAmount: amountValue,
            foreignCurrency: entryCurrency.rawValue,
            fxRate: fxRate
        )
    }

    /// Same FX-conversion contract as `TransactionFormView.crossConvert`:
    /// returns the input unchanged when either rate is missing instead of
    /// silently producing a 75×-off value (see ADR-001 / 2026-04-19 incident).
    static func crossConvert(amount: Decimal, from: CurrencyCode, to: CurrencyCode, using cm: CurrencyManager) -> Decimal {
        guard from != to else { return amount }
        guard let fromRate = cm.rates[from.rawValue], fromRate > 0,
              let toRate   = cm.rates[to.rawValue],   toRate > 0 else {
            return amount
        }
        return amount / Decimal(fromRate) * Decimal(toRate)
    }
}
