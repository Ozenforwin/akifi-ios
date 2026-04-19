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

    // Payment source state
    /// Selected source account. `nil` means "same as target" (regular expense, no auto-transfer).
    @State private var selectedPaymentSourceId: String?
    /// `accountId → defaultSourceId` loaded from `user_account_defaults` on appear.
    @State private var userDefaults: [String: String] = [:]
    private let defaultsRepo = UserAccountDefaultsRepository()

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

    // MARK: - Payment-source helpers

    private var selectedAccount: Account? {
        guard let id = selectedAccountId else { return nil }
        return accounts.first { $0.id == id }
    }

    private var currentUserId: String? {
        appViewModel.dataStore.profile?.id
    }

    /// True iff the target account has transactions from more than one user,
    /// i.e. it's considered shared for the current user. Falls back to false
    /// when we have no profile yet.
    private var targetIsShared: Bool {
        guard let acc = selectedAccount, let uid = currentUserId else { return false }
        return appViewModel.dataStore.transactions.contains { $0.accountId == acc.id && $0.userId != uid }
            || acc.userId != uid
    }

    /// Eligible source accounts for the picker — own accounts in the same
    /// currency as the target. Always includes the target itself as "this account".
    private var eligibleSources: [Account] {
        guard let target = selectedAccount, let uid = currentUserId else { return [] }
        return accounts.filter { acc in
            acc.userId == uid && acc.id != target.id && acc.currency.lowercased() == target.currency.lowercased()
        }
    }

    /// True if the payment-source picker should be shown at all. Only
    /// surfaces for expenses on a shared target account that has at least
    /// one eligible personal source.
    private var shouldShowPaymentSource: Bool {
        selectedType == .expense && !isEditing && targetIsShared && !eligibleSources.isEmpty
    }

    /// True iff we should disable the picker entirely (e.g. currency mismatch
    /// with every own account — already filtered out, so this is effectively
    /// "no eligible sources"). Kept as separate flag for extension.
    private var paymentSourceDisabled: Bool { eligibleSources.isEmpty }

    private func paymentSourceLabel(for acc: Account) -> String {
        let starred = userDefaults[selectedAccountId ?? ""] == acc.id
        let starSuffix = starred ? " ⭐" : ""
        return "\(acc.icon) \(acc.name)\(starSuffix)"
    }

    private var selfPaymentLabel: String {
        String(localized: "tx.paymentSource.self")
    }

    // MARK: - View

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

                if !accounts.isEmpty {
                    Section(String(localized: "common.account")) {
                        Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                            Text(String(localized: "transaction.noAccount")).tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                        .onChange(of: selectedAccountId) { _, newValue in
                            // When target changes, auto-pick the stored default (if any) and of matching currency.
                            guard let newId = newValue,
                                  let target = accounts.first(where: { $0.id == newId }) else {
                                selectedPaymentSourceId = nil
                                return
                            }
                            if let defaultId = userDefaults[newId],
                               let src = accounts.first(where: { $0.id == defaultId }),
                               src.currency.lowercased() == target.currency.lowercased() {
                                selectedPaymentSourceId = defaultId
                            } else {
                                selectedPaymentSourceId = nil  // = target (no auto-transfer)
                            }
                        }
                    }
                }

                if shouldShowPaymentSource {
                    paymentSourceSection
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
            .task {
                await loadUserDefaults()
            }
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

    // MARK: - Payment source section

    @ViewBuilder
    private var paymentSourceSection: some View {
        Section(String(localized: "tx.paymentSource")) {
            Picker(selection: $selectedPaymentSourceId) {
                Text(selfPaymentLabel).tag(nil as String?)
                ForEach(eligibleSources) { acc in
                    Text(paymentSourceLabel(for: acc)).tag(acc.id as String?)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(paymentSourceDisabled)

            if paymentSourceDisabled {
                Text(String(localized: "tx.paymentSource.hint.currencyMismatch"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let sourceId = selectedPaymentSourceId,
                      let source = accounts.first(where: { $0.id == sourceId }),
                      let target = selectedAccount {
                // Live preview hint: "We'll create a transfer of X from A to B."
                // Format the raw entered amount in the transaction's currency —
                // do NOT run through CurrencyManager.formatAmount, which would
                // convert between user's display currency and assume RUB input.
                let amountValue = calculatorState.getResult() ?? 0
                let amountStr = Self.formatRawAmount(amountValue, currency: selectedCurrency)
                let hint = String(format: String(localized: "tx.paymentSource.hint.autoTransfer"),
                                  amountStr, source.name, target.name)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Load defaults

    private func loadUserDefaults() async {
        do {
            let rows = try await defaultsRepo.fetchAll()
            var map: [String: String] = [:]
            for r in rows {
                if let src = r.defaultSourceId { map[r.accountId] = src }
            }
            userDefaults = map

            // Re-evaluate the default for the currently selected account, if one is picked.
            if let accId = selectedAccountId,
               let target = accounts.first(where: { $0.id == accId }),
               selectedPaymentSourceId == nil,
               let def = map[accId],
               let src = accounts.first(where: { $0.id == def }),
               src.currency.lowercased() == target.currency.lowercased() {
                selectedPaymentSourceId = def
            }
        } catch {
            // Silent — defaults are optional UX.
            AppLogger.data.debug("paymentDefaults load: \(error.localizedDescription)")
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
        selectedPaymentSourceId = tx.paymentSourceAccountId
        if let txDate = Self.isoDateTimeFormatter.date(from: tx.rawDateTime) ?? Self.isoDateFormatter.date(from: tx.date) {
            date = txDate
        }
    }

    // MARK: - Save

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
                // Route through auto-transfer update RPC only when this is an expense
                // with an existing auto_transfer_group_id and no transfer_group_id
                // (i.e. it's the main expense row, not a transfer leg).
                let useAutoUpdate = tx.type == .expense
                    && tx.autoTransferGroupId != nil
                    && tx.transferGroupId == nil
                let input = UpdateTransactionInput(
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil,
                    useAutoTransferUpdate: useAutoUpdate
                )
                try await appViewModel.dataStore.updateTransaction(id: tx.id, input)
            } else {
                // Resolve payment source — only record it when target is shared AND source != target.
                let resolvedPaymentSource: String? = {
                    guard selectedType == .expense,
                          let sourceId = selectedPaymentSourceId,
                          sourceId != selectedAccountId
                    else { return nil }
                    return sourceId
                }()
                let input = CreateTransactionInput(
                    user_id: userId,
                    account_id: selectedAccountId,
                    amount: amountInBase,
                    currency: selectedCurrency.rawValue,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil,
                    payment_source_account_id: resolvedPaymentSource
                )
                _ = try await appViewModel.dataStore.addTransaction(input)

                // Auto-upsert default for next time.
                if let targetId = selectedAccountId,
                   let resolvedPaymentSource,
                   userDefaults[targetId] != resolvedPaymentSource {
                    Task.detached(priority: .background) { [defaultsRepo] in
                        try? await defaultsRepo.upsert(accountId: targetId, defaultSourceId: resolvedPaymentSource)
                    }
                    userDefaults[targetId] = resolvedPaymentSource
                }
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Formats an amount already expressed in the transaction's currency
    /// without running it through CurrencyManager (which converts from RUB
    /// to the user's display currency and would corrupt the number when
    /// the transaction is in USD / EUR / etc).
    nonisolated static func formatRawAmount(_ amount: Decimal, currency: CurrencyCode) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.groupingSeparator = " "
        let formatted = formatter.string(from: abs(amount) as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
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
