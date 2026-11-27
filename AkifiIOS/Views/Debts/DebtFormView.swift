import SwiftUI

/// Sheet wrapper for adding a person or editing a debt's details.
struct DebtFormSheet: View {
    let mode: DebtForm.Mode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DebtForm(mode: mode) { dismiss() }
        }
    }
}

/// «Дал в долг» / «Взял в долг» for a new person — кому, сколько, с какого
/// счёта, срок — in one sheet (contract §A5: `create_debt`, then the first
/// transfer); or editing a debt's details. A new debt always starts with
/// money and is kept in the amount's currency.
struct DebtForm: View {
    enum Mode {
        /// `initial`: preselected first movement (quick add «Дал/Взял в долг»).
        case create(initial: DebtAction?)
        case edit(DebtEntry)
    }

    let mode: Mode
    let onDone: () -> Void

    @Environment(AppViewModel.self) private var appViewModel
    @State private var name = ""
    @State private var contact = ""
    @State private var currency: Currency = .rub
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var remind = false
    @State private var note = ""
    @State private var firstAction: DebtAction?
    @State private var amountText = ""
    @State private var realAccountId: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// A debt `create_debt` already wrote — a retry only records the movement.
    @State private var createdAccount: Account?
    @State private var didPrefill = false
    @FocusState private var nameFocused: Bool

    private var dataStore: DataStore { appViewModel.dataStore }
    private var debts: DebtsStore { appViewModel.debts }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amount: Decimal? { DebtFormat.parseAmount(amountText) }

    private var isValid: Bool {
        guard (1...120).contains(trimmedName.count), contact.count <= 200, note.count <= 2000 else { return false }
        // A debt always starts with money: «Я дал» / «Я взял» и сумма.
        if isCreate { return amount != nil && realAccountId != nil }
        return true
    }

    private var action: DebtAction { firstAction ?? .lend }

    var body: some View {
        Form {
            if isCreate {
                // «Я дал» / «Я взял», кому, сколько, с какого счёта — one
                // sheet. The person is created on save; the debt is kept in
                // the amount's currency (no separate currency choice, no
                // «без суммы» — device feedback 2026-11-28).
                Section {
                    Picker(String(localized: "debts.form.first"), selection: Binding(
                        get: { action },
                        set: { firstAction = $0 }
                    )) {
                        Text(String(localized: "debts.form.first.lend")).tag(DebtAction.lend)
                        Text(String(localized: "debts.form.first.borrow")).tag(DebtAction.borrow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(createdAccount != nil)
                }
            }

            Section {
                TextField(String(localized: "debts.form.name"), text: $name)
                    .textContentType(.name)
                    .focused($nameFocused)
                    .disabled(createdAccount != nil)
                TextField(String(localized: "debts.form.contact"), text: $contact)
                    .textContentType(.telephoneNumber)
            }

            if isCreate {
                moneySection
            }

            Section {
                Toggle(String(localized: "debts.form.dueDate"), isOn: $hasDueDate.animation())
                if hasDueDate {
                    DatePicker(String(localized: "debts.form.dueDate.date"), selection: $dueDate, displayedComponents: .date)
                    Toggle(String(localized: "debts.form.remind"), isOn: $remind)
                }
            } footer: {
                if hasDueDate && remind {
                    Text(String(localized: "debts.form.remind.footer"))
                }
            }

            Section(String(localized: "debts.form.note")) {
                TextField(String(localized: "debts.form.note.placeholder"), text: $note, axis: .vertical)
                    .lineLimit(2...6)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.expense)
                }
            }
        }
        .navigationTitle(isCreate ? action.title : String(localized: "debts.editDetails"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "common.cancel")) { onDone() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "common.save")) {
                    Task { await save() }
                }
                .disabled(!isValid || isSaving)
            }
        }
        .onAppear(perform: prefill)
    }

    @ViewBuilder
    private var moneySection: some View {
        Section {
            HStack {
                TextField(String(localized: "debts.amount.placeholder"), text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.title3.monospacedDigit())
                ActiveCurrencyPicker(selection: $currency)
                    .disabled(createdAccount != nil)
            }
            Picker(action == .lend ? String(localized: "debts.account.from") : String(localized: "debts.account.to"),
                   selection: $realAccountId) {
                ForEach(dataStore.accounts) { acc in
                    Text("\(acc.icon) \(acc.name)").tag(acc.id as String?)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text(String(localized: "common.amount"))
        } footer: {
            if createdAccount != nil {
                Text(String(localized: "debts.form.retryMovement"))
            } else {
                Text(String(localized: "debts.form.amount.footer"))
            }
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        realAccountId = (dataStore.accounts.first(where: \.isPrimary) ?? dataStore.accounts.first)?.id
        switch mode {
        case .create(let initial):
            firstAction = initial ?? .lend
            currency = cm.dataCurrency
            nameFocused = true
        case .edit(let entry):
            name = entry.name
            contact = entry.contact ?? ""
            currency = Currency(code: entry.currency) ?? cm.dataCurrency
            if let day = AppDateFormatters.day(entry.dueDate) {
                hasDueDate = true
                dueDate = day
            }
            remind = entry.remind
            note = entry.note ?? ""
        }
    }

    private var dueDateString: String? {
        hasDueDate ? AppDateFormatters.localDate.string(from: dueDate) : nil
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            switch mode {
            case .edit(let entry):
                try await debts.updateDetails(
                    accountId: entry.accountId, name: trimmedName, contact: contact,
                    dueDate: dueDateString, remind: hasDueDate && remind, note: note, dataStore: dataStore
                )
                onDone()
            case .create:
                let account: Account
                if let createdAccount {
                    account = createdAccount
                } else {
                    account = try await debts.createDebt(
                        DebtsStore.NewDebt(
                            name: trimmedName, currency: currency.code, contact: contact,
                            dueDate: dueDateString, remind: hasDueDate && remind, note: note
                        ),
                        dataStore: dataStore
                    )
                    createdAccount = account
                }
                if let amount,
                   let real = dataStore.accounts.first(where: { $0.id == realAccountId }) {
                    try await debts.record(
                        action, amount: amount, entryCurrency: currency, debtAccount: account,
                        realAccount: real, counterpartyName: trimmedName, date: Date(), comment: nil,
                        dataStore: dataStore, currencyManager: cm
                    )
                } else {
                    await debts.refresh(dataStore: dataStore)
                }
                HapticManager.success()
                onDone()
            }
        } catch {
            // `create_debt` succeeded but the movement failed: the person
            // stays at 0 («в расчёте»); the form keeps it and a second Save
            // only retries the movement (contract §A5).
            errorMessage = FormErrorMessage.text(for: error)
        }
    }
}

/// Entry point for quick add («+» / FAB): opens «Дал в долг» / «Взял в долг»
/// (or any of the four actions) directly. Pick an existing person or add a
/// new one — the first movement is recorded in the same flow.
///
/// For the Liquid Glass / quick-add stream (this stream does not edit
/// `ContentView` / `FABView`): add a case to the sheet router and present
///
/// ```swift
/// case .debt(let action):
///     DebtQuickActionSheet(action: action)   // .lend or .borrow
/// ```
///
/// It reads `AppViewModel` from the environment like every other sheet and
/// dismisses itself after saving.
struct DebtQuickActionSheet: View {
    let action: DebtAction
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entries = appViewModel.debts.entries(dataStore: appViewModel.dataStore).filter(\.isOpen)
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        DebtForm(mode: .create(initial: action == .lend || action == .borrow ? action : nil)) { dismiss() }
                    } label: {
                        Label(String(localized: "debts.addPerson"), systemImage: "person.badge.plus")
                    }
                }
                if !entries.isEmpty {
                    Section(String(localized: "debts.quick.people")) {
                        ForEach(entries) { entry in
                            NavigationLink {
                                DebtMovementForm(debtAccountId: entry.accountId, mode: .new(action)) { dismiss() }
                            } label: {
                                DebtRow(entry: entry)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
            }
            .task { await appViewModel.debts.refresh(dataStore: appViewModel.dataStore) }
        }
    }
}
