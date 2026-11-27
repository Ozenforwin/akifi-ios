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
    /// Entry currency (M4): follows the SOURCE account until the user picks
    /// one in the picker.
    @State private var entryCurrency = EntryCurrencyState(.rub)
    private var selectedCurrency: CurrencyCode { entryCurrency.currency }
    private var currencyPickerSelection: Binding<CurrencyCode> {
        Binding(
            get: { entryCurrency.currency },
            set: { entryCurrency.userSelected($0) }
        )
    }
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Entry as loaded in `prefillIfEditing` — when amount, currency and
    /// both accounts are unchanged on save, each leg keeps its stored
    /// amounts and frozen rate instead of being re-priced today (M10).
    @State private var baseline: Baseline?

    private struct Baseline: Equatable {
        let amount: Decimal?
        let currency: CurrencyCode
        let fromAccountId: String?
        let toAccountId: String?
    }

    private var isEditing: Bool { editingTransaction != nil }

    /// Editing a legacy one-row transfer (M15): only the row's own side is
    /// known, and it is updated in place — "Update" used to insert a new
    /// pair and leave the old row, debiting the account twice.
    private var legacyRow: Transaction? {
        guard let tx = editingTransaction, tx.isLegacySingleRowTransfer else { return nil }
        return tx
    }

    init(accounts: [Account], editingTransaction: Transaction? = nil, onSave: @escaping () async -> Void) {
        self.accounts = accounts
        self.editingTransaction = editingTransaction
        self.onSave = onSave
    }

    private var isValid: Bool {
        guard let amount = calculatorState.getResult(), amount > 0 else { return false }
        if let legacy = legacyRow {
            return (legacy.movesMoneyOut ? fromAccountId : toAccountId) != nil
        }
        return fromAccountId != nil &&
               toAccountId != nil &&
               fromAccountId != toAccountId
    }

    var body: some View {
        // M2: the two legs of an auto-transfer belong to their main expense
        // (`create_expense_with_auto_transfer` writes all three rows). This
        // form used to re-price both legs at today's rate and leave the
        // expense alone — money out of thin air on the shared account.
        // Open the expense instead; when RLS hides it, read-only.
        if let leg = editingTransaction, leg.isAutoTransferLeg {
            if let main = appViewModel.dataStore.mainExpense(forAutoTransferLeg: leg) {
                TransactionFormView(
                    categories: appViewModel.dataStore.displayCategories,
                    accounts: accounts,
                    editingTransaction: main,
                    onSave: onSave
                )
            } else {
                autoTransferLegReadOnly
            }
        } else {
            transferForm
        }
    }

    /// Shown for an auto-transfer leg whose main expense this device cannot
    /// see (it lives on an account RLS hides).
    private var autoTransferLegReadOnly: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(
                        format: String(localized: "tx.autoTransfer.legReadOnly.body"),
                        Self.expenseName(fromLegDescription: editingTransaction?.description)
                    ))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(String(localized: "tx.autoTransfer.legReadOnly.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
            }
        }
    }

    /// The RPC titles legs "Авто-перевод: <expense description>".
    static func expenseName(fromLegDescription description: String?) -> String {
        let prefix = "Авто-перевод: "
        guard let description, !description.isEmpty else { return String(localized: "transaction.transfer") }
        return description.hasPrefix(prefix) ? String(description.dropFirst(prefix.count)) : description
    }

    private var transferForm: some View {
        NavigationStack {
            Form {
                Section(String(localized: "transfer.amount")) {
                    CalculatorKeyboardView(state: calculatorState)
                }

                if legacyRow.map({ $0.movesMoneyOut }) ?? true {
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
                }

                if legacyRow.map({ !$0.movesMoneyOut }) ?? true {
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
                }

                Section(String(localized: "transfer.details")) {
                    TextField(String(localized: "transfer.comment"), text: $description)
                    DatePicker(String(localized: "common.date"), selection: $date, displayedComponents: .date)
                    HStack {
                        Text(String(localized: "common.currency"))
                            .foregroundStyle(.primary)
                        Spacer()
                        ActiveCurrencyPicker(selection: currencyPickerSelection)
                    }
                    .frame(minHeight: 44)
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
            .onChange(of: fromAccountId) { _, newId in
                // New transfer: the amount is in the source account's
                // currency until the user picks another (M4).
                guard !isEditing else { return }
                entryCurrency.follow(
                    accountCurrency: newId.flatMap { id in accounts.first(where: { $0.id == id }) }?.currencyCode
                )
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

    private func prefillIfEditing() {
        guard let tx = editingTransaction else {
            // M4: the source account's currency, not the display currency.
            let source = fromAccountId.flatMap { id in accounts.first(where: { $0.id == id }) }
            entryCurrency.load(source?.currencyCode ?? appViewModel.currencyManager.selectedCurrency)
            return
        }

        let cm = appViewModel.currencyManager
        let dataStore = appViewModel.dataStore

        description = tx.description ?? ""

        // D8: keep the stored time — see `TransactionFormDates`.
        if let txDate = TransactionFormDates.parse(rawDateTime: tx.rawDateTime, fallbackDate: tx.date) {
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
        if tx.isLegacySingleRowTransfer {
            // M15: one row, one known side.
            sourceLeg = tx
            destLeg = nil
            if tx.movesMoneyOut {
                fromAccountId = tx.accountId
            } else {
                toAccountId = tx.accountId
            }
        } else if tx.movesMoneyOut {
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
           let code = Currency(code: foreignCur.uppercased()) {
            entryCurrency.load(code)
            calculatorState.setValue(abs(foreign))
        } else {
            // Fall back to the source leg's account currency.
            let srcAccount = dataStore.accounts.first { $0.id == sourceLeg.accountId }
            let srcCode = srcAccount?.currencyCode ?? cm.dataCurrency
            entryCurrency.load(srcCode)
            calculatorState.setValue(abs(sourceLeg.amountNative.displayAmount))
        }

        baseline = Baseline(
            amount: calculatorState.getResult(),
            currency: selectedCurrency,
            fromAccountId: fromAccountId,
            toAccountId: toAccountId
        )
    }

    private func save() async {
        if let legacy = legacyRow {
            await saveLegacyRow(legacy)
            return
        }
        guard let amountValue = calculatorState.getResult(),
              amountValue > 0,
              let fromId = fromAccountId,
              let toId = toAccountId else {
            errorMessage = String(localized: "transfer.fillAllFields")
            return
        }

        // D8: write the full wall-clock timestamp. The picker edits only the
        // day, so an edit keeps the stored time (it used to write the bare
        // date — midnight — on every save).
        let dateStr = TransactionFormDates.string(from: date)
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
            return
        }

        // Existing legs when editing. Source = expense leg, destination =
        // income leg (same resolution as `prefillIfEditing`).
        var expenseLeg: Transaction?
        var incomeLeg: Transaction?
        if let tx = editingTransaction, let groupId = tx.transferGroupId {
            let pair = dataStore.transactions.first { $0.transferGroupId == groupId && $0.id != tx.id }
            if tx.movesMoneyOut {
                expenseLeg = tx
                incomeLeg = pair
            } else {
                expenseLeg = pair ?? tx
                incomeLeg = pair != nil ? tx : nil
            }
        }

        // M10: nothing about the money changed → keep both legs as stored.
        let unchanged = isEditing && baseline == Baseline(
            amount: amountValue,
            currency: selectedCurrency,
            fromAccountId: fromId,
            toAccountId: toId
        )

        // M3: a leg whose currency cannot be converted is refused, never
        // written 1:1. M5: only real, recent quotes are frozen into a leg.
        let rates = await cm.ratesForWrite([
            selectedCurrency.code, fromAccount.currencyCode.code, toAccount.currencyCode.code,
        ])
        let fromLeg: LegFields
        let toLeg: LegFields
        do {
            fromLeg = try Self.legFields(
                amountValue: amountValue, entryCurrency: selectedCurrency, account: fromAccount,
                rates: rates, unchangedLeg: unchanged ? expenseLeg : nil
            )
            toLeg = try Self.legFields(
                amountValue: amountValue, entryCurrency: selectedCurrency, account: toAccount,
                rates: rates, unchangedLeg: unchanged ? incomeLeg : nil
            )
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
            return
        }

        isLoading = true
        do {
            // Always source user_id from the live Supabase session.
            // `dataStore.profile?.id` can be stale right after sign-in or
            // token refresh, and mismatch → RLS violation on INSERT.
            let userId = try await SupabaseManager.shared.currentUserId()

            if let tx = editingTransaction, tx.transferGroupId != nil {
                // Editing: update both sides of the transfer
                let expenseTxId = expenseLeg?.id ?? tx.id
                let incomeTxId = incomeLeg?.id

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
            errorMessage = FormErrorMessage.text(for: error)
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

    /// - `unchangedLeg`: the stored leg on this account when the caller saw
    ///   amount, currency and accounts unchanged → its amounts and frozen
    ///   rate are kept verbatim (M10).
    /// - Throws `MissingFXRateError` when the entry has to be converted and
    ///   a rate is missing (M3) — no 1:1 leg is ever produced.
    static func legFields(
        amountValue: Decimal,
        entryCurrency: CurrencyCode,
        account: Account,
        rates: [String: Double],
        unchangedLeg: Transaction? = nil
    ) throws -> LegFields {
        let accountCode = account.currencyCode
        let currencyLabel = accountCode.code
        if let stored = unchangedLeg, stored.accountId == account.id {
            return LegFields(
                amountInAccount: stored.amountNative.displayAmount,
                currencyLabel: currencyLabel,
                foreignAmount: stored.foreignAmount,
                foreignCurrency: stored.foreignCurrency,
                fxRate: stored.fxRate
            )
        }
        if entryCurrency == accountCode {
            return LegFields(
                amountInAccount: amountValue,
                currencyLabel: currencyLabel,
                foreignAmount: nil,
                foreignCurrency: nil,
                fxRate: nil
            )
        }
        let amountInAccount = try TransactionMath.convertForStorage(
            amountValue, from: entryCurrency.code, to: accountCode.code, rates: rates
        )
        let fxRate: Decimal? = amountValue != 0 ? (amountInAccount / amountValue) : nil
        return LegFields(
            amountInAccount: amountInAccount,
            currencyLabel: currencyLabel,
            foreignAmount: amountValue,
            foreignCurrency: entryCurrency.code,
            fxRate: fxRate
        )
    }

    static func legFields(amountValue: Decimal, entryCurrency: CurrencyCode, account: Account, cm: CurrencyManager) throws -> LegFields {
        try legFields(amountValue: amountValue, entryCurrency: entryCurrency, account: account, rates: cm.writeRates())
    }

    // MARK: - Legacy one-row transfer (M15)

    private func saveLegacyRow(_ stored: Transaction) async {
        let accountId = stored.movesMoneyOut ? fromAccountId : toAccountId
        guard let amountValue = calculatorState.getResult(), amountValue > 0,
              let accountId,
              let account = accounts.first(where: { $0.id == accountId }) else {
            errorMessage = String(localized: "transfer.fillAllFields")
            return
        }
        let cm = appViewModel.currencyManager
        let unchanged = baseline == Baseline(
            amount: amountValue, currency: selectedCurrency,
            fromAccountId: fromAccountId, toAccountId: toAccountId
        )
        let rates = await cm.ratesForWrite([selectedCurrency.code, account.currencyCode.code])
        let input: UpdateTransactionInput
        do {
            input = try Self.legacyRowUpdate(
                stored: stored,
                amountValue: amountValue,
                entryCurrency: selectedCurrency,
                account: account,
                rates: rates,
                unchanged: unchanged,
                date: TransactionFormDates.string(from: date),
                description: description.isEmpty ? nil : description
            )
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
            return
        }
        isLoading = true
        do {
            try await appViewModel.dataStore.updateTransaction(id: stored.id, input)
            await onSave()
            dismiss()
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }
        isLoading = false
    }

    /// The in-place update of a legacy one-row transfer: still ONE `.transfer`
    /// row whose sign is its direction (`NativeBalance.signedAmount`), on
    /// `account` (the user may move it to another account of the same side).
    /// No second leg is created — the counter-account was never recorded and
    /// its balance never moved.
    static func legacyRowUpdate(
        stored: Transaction,
        amountValue: Decimal,
        entryCurrency: CurrencyCode,
        account: Account,
        rates: [String: Double],
        unchanged: Bool,
        date: String,
        description: String?
    ) throws -> UpdateTransactionInput {
        let leg = try legFields(
            amountValue: amountValue, entryCurrency: entryCurrency, account: account,
            rates: rates, unchangedLeg: unchanged ? stored : nil
        )
        let sign: Decimal = stored.movesMoneyOut ? -1 : 1
        let native = sign * abs(leg.amountInAccount)
        return UpdateTransactionInput(
            amount: native,
            amount_native: native,
            currency: leg.currencyLabel,
            foreign_amount: leg.foreignAmount.map { sign * abs($0) },
            foreign_currency: leg.foreignCurrency,
            fx_rate: leg.fxRate.map { abs($0) },
            date: date,
            description: description,
            account_id: account.id,
            replaceCurrencyFields: true
        )
    }

    /// DISPLAY-ONLY conversion (same contract as
    /// `TransactionFormView.crossConvert`): returns the input unchanged when
    /// either rate is missing. Never used to build a leg — see `legFields`.
    static func crossConvert(amount: Decimal, from: CurrencyCode, to: CurrencyCode, using cm: CurrencyManager) -> Decimal {
        guard from != to else { return amount }
        guard let fromRate = cm.rates[from.code], fromRate > 0,
              let toRate   = cm.rates[to.code],   toRate > 0 else {
            return amount
        }
        return amount / Decimal(fromRate) * Decimal(toRate)
    }
}
