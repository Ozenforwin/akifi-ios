import SwiftUI

/// Sheet wrapper: a new «Дал в долг» / «Мне вернули» / «Взял в долг» /
/// «Я вернул», or an edit of an existing movement (both legs).
struct DebtMovementSheet: View {
    let debtAccountId: String
    let mode: DebtMovementForm.Mode
    @Environment(\.dismiss) private var dismiss

    init(debtAccountId: String, action: DebtAction) {
        self.debtAccountId = debtAccountId
        self.mode = .new(action)
    }

    init(debtAccountId: String, editing leg: Transaction) {
        self.debtAccountId = debtAccountId
        self.mode = .edit(leg)
    }

    var body: some View {
        NavigationStack {
            DebtMovementForm(debtAccountId: debtAccountId, mode: mode) { dismiss() }
        }
        .presentationDetents([.large])
    }
}

/// The form itself — also pushed inside `DebtQuickActionSheet`.
struct DebtMovementForm: View {
    enum Mode {
        case new(DebtAction)
        case edit(Transaction)
    }

    let debtAccountId: String
    let mode: Mode
    let onDone: () -> Void

    @Environment(AppViewModel.self) private var appViewModel
    @State private var amountText = ""
    @State private var entryCurrency: Currency = .rub
    @State private var realAccountId: String?
    @State private var date = Date()
    @State private var comment = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingFlip: DebtsStore.PreparedMovement?
    @State private var showSettledPrompt = false
    @State private var didPrefill = false
    @FocusState private var amountFocused: Bool

    private var dataStore: DataStore { appViewModel.dataStore }
    private var debts: DebtsStore { appViewModel.debts }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var debtAccount: Account? { dataStore.account(withId: debtAccountId) }
    private var entry: DebtEntry? { debts.entry(accountId: debtAccountId, dataStore: dataStore) }
    /// Money accounts only — never another debt (contract §A5).
    private var realAccounts: [Account] { dataStore.accounts }
    private var realAccount: Account? { realAccounts.first { $0.id == realAccountId } }

    private var action: DebtAction {
        switch mode {
        case .new(let action): return action
        case .edit(let leg): return Self.direction(of: leg, debtAccountId: debtAccountId)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Pinned at the top of the currency menu: the debt's and the real
    /// account's (any other currency is converted per leg on save).
    private var currencyChoices: [Currency] {
        var out: [Currency] = []
        if let debt = debtAccount?.currencyCode { out.append(debt) }
        if let real = realAccount?.currencyCode, !out.contains(real) { out.append(real) }
        return out
    }

    private var amount: Decimal? { DebtFormat.parseAmount(amountText) }

    var body: some View {
        Form {
            if let entry {
                Section {
                    LabeledContent(entry.name) {
                        Text(DebtFormat.amount(entry.balance, currency: entry.currency, cm: cm))
                            .monospacedDigit()
                            .foregroundStyle(DebtFormat.color(entry.direction))
                    }
                } footer: {
                    Text(DebtFormat.directionCaption(entry.direction))
                }
            }

            Section(String(localized: "common.amount")) {
                HStack {
                    TextField(String(localized: "debts.amount.placeholder"), text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($amountFocused)
                    ActiveCurrencyPicker(selection: $entryCurrency, pinned: currencyChoices)
                }
            }

            Section {
                Picker(accountPickerTitle, selection: $realAccountId) {
                    ForEach(realAccounts) { acc in
                        Text("\(acc.icon) \(acc.name)").tag(acc.id as String?)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(action.movesIntoDebt ? String(localized: "debts.account.footer.out") : String(localized: "debts.account.footer.in"))
            }

            Section {
                DatePicker(String(localized: "common.date"), selection: $date, displayedComponents: .date)
                TextField(String(localized: "debts.comment"), text: $comment)
            }

            if let warning = flipWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.warning)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.expense)
                }
            }
        }
        .navigationTitle(isEditing ? String(localized: "common.editing") : action.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "common.cancel")) { onDone() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? String(localized: "common.update") : String(localized: "common.save")) {
                    Task { await save() }
                }
                .disabled(amount == nil || realAccount == nil || isSaving)
            }
        }
        .onAppear(perform: prefill)
        .onChange(of: realAccountId) { old, _ in
            // Follow the account only when the amount was in the previous
            // account's currency; a currency the user picked stays.
            let oldCurrency = old.flatMap { id in realAccounts.first(where: { $0.id == id })?.currencyCode }
            if entryCurrency == oldCurrency, entryCurrency != debtAccount?.currencyCode,
               let real = realAccount?.currencyCode {
                entryCurrency = real
            }
        }
        .alert(
            String(localized: "debts.flip.title"),
            isPresented: Binding(get: { pendingFlip != nil }, set: { if !$0 { pendingFlip = nil } }),
            presenting: pendingFlip
        ) { prepared in
            Button(String(localized: "debts.flip.confirm")) {
                Task { await commit(prepared) }
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "debts.flip.message"))
        }
        .alert(String(localized: "debts.settled.title"), isPresented: $showSettledPrompt) {
            Button(String(localized: "debts.close")) {
                Task {
                    try? await debts.setClosed(accountId: debtAccountId, closed: true, dataStore: dataStore)
                    onDone()
                }
            }
            Button(String(localized: "debts.settled.keep"), role: .cancel) { onDone() }
        } message: {
            Text(String(localized: "debts.settled.message"))
        }
    }

    private var accountPickerTitle: String {
        action.movesIntoDebt ? String(localized: "debts.account.from") : String(localized: "debts.account.to")
    }

    /// Shown live while typing a repayment in the debt's currency.
    private var flipWarning: String? {
        guard !isEditing, let entry, let amount, entryCurrency == debtAccount?.currencyCode,
              action.flipsSign(amount: amount.kopecks, balance: entry.balance) else { return nil }
        return String(localized: "debts.flip.inline")
    }

    // MARK: - Prefill

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        let primary = realAccounts.first(where: \.isPrimary) ?? realAccounts.first
        switch mode {
        case .new(let action):
            realAccountId = primary?.id
            entryCurrency = debtAccount?.currencyCode ?? cm.dataCurrency
            if let entry, let minor = action.defaultAmount(balance: entry.balance) {
                amountText = DebtFormat.fieldText(minor)
            } else {
                amountFocused = true
            }
        case .edit(let leg):
            guard let group = leg.manualTransferGroupId else { return }
            let legs = dataStore.transactions.filter { $0.isManualTransferLeg(ofGroup: group) }
            let debtLeg = legs.first { $0.accountId == debtAccountId } ?? leg
            let realLeg = legs.first { $0.id != debtLeg.id }
            realAccountId = realLeg?.accountId ?? primary?.id
            if let foreign = debtLeg.foreignAmount, let code = debtLeg.foreignCurrency.flatMap(Currency.init(code:)) {
                entryCurrency = code
                amountText = NSDecimalNumber(decimal: abs(foreign)).stringValue
            } else if let foreign = realLeg?.foreignAmount, let code = realLeg?.foreignCurrency.flatMap(Currency.init(code:)) {
                entryCurrency = code
                amountText = NSDecimalNumber(decimal: abs(foreign)).stringValue
            } else {
                entryCurrency = debtAccount?.currencyCode ?? cm.dataCurrency
                amountText = DebtFormat.fieldText(debtLeg.amountNative)
            }
            if let day = TransactionFormDates.parse(rawDateTime: debtLeg.rawDateTime, fallbackDate: debtLeg.date) {
                date = day
            }
            comment = Self.comment(from: debtLeg.description)
        }
    }

    /// «Долг: Маша · на ремонт» → «на ремонт».
    static func comment(from description: String?) -> String {
        guard let description, let range = description.range(of: " · ") else { return "" }
        return String(description[range.upperBound...])
    }

    /// Direction of an existing movement: debt leg income = money went to them.
    static func direction(of leg: Transaction, debtAccountId: String) -> DebtAction {
        let onDebt = leg.accountId == debtAccountId
        let debtLegIsIncome = onDebt ? leg.type == .income : leg.type == .expense
        return debtLegIsIncome ? .lend : .borrow
    }

    // MARK: - Save

    private func save() async {
        guard let amount, let debtAccount, let realAccount else {
            errorMessage = String(localized: "transfer.fillAllFields")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let name = entry?.name ?? debtAccount.name
        let note = comment.isEmpty ? nil : comment
        do {
            switch mode {
            case .edit(let leg):
                try await debts.updateMovement(
                    leg, amount: amount, entryCurrency: entryCurrency, debtAccount: debtAccount,
                    realAccount: realAccount, counterpartyName: name, date: date, comment: note,
                    dataStore: dataStore, currencyManager: cm
                )
                onDone()
            case .new(let action):
                let prepared = try await debts.prepare(
                    action, amount: amount, entryCurrency: entryCurrency, debtAccount: debtAccount,
                    realAccount: realAccount, counterpartyName: name, date: date, comment: note,
                    currencyManager: cm
                )
                if action.flipsSign(amount: prepared.debtAmountMinor, balance: entry?.balance ?? 0) {
                    pendingFlip = prepared
                    return
                }
                await commit(prepared)
            }
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }
    }

    private func commit(_ prepared: DebtsStore.PreparedMovement) async {
        let before = entry?.balance ?? 0
        isSaving = true
        defer { isSaving = false }
        do {
            try await debts.commit(prepared, dataStore: dataStore)
            HapticManager.success()
            if prepared.action.settles(amount: prepared.debtAmountMinor, balance: before), entry?.hasDetails == true {
                showSettledPrompt = true
            } else {
                onDone()
            }
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }
    }
}
