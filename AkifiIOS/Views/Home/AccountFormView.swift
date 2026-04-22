import SwiftUI

struct AccountFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let editingAccount: Account?
    let onSave: () async -> Void

    @State private var name = ""
    @State private var selectedIcon = "💳"
    @State private var selectedColor = "#A78BFA"
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var initialBalanceText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showShareSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    private let accountRepo = AccountRepository()

    private let icons = ["💳", "🏦", "💰", "👛", "💵", "🪙", "💎", "🏠", "🚗", "✈️", "🎓", "📱"]
    private let colors = ["#4ADE80", "#60A5FA", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399", "#38BDF8", "#C084FC"]

    private var isEditing: Bool { editingAccount != nil }

    init(editingAccount: Account? = nil, onSave: @escaping () async -> Void) {
        self.editingAccount = editingAccount
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "common.name")) {
                    TextField(String(localized: "account.namePlaceholder"), text: $name)
                }

                Section {
                    HStack {
                        TextField("0", text: $initialBalanceText)
                            .keyboardType(.decimalPad)
                        Text(selectedCurrency.symbol)
                            .foregroundStyle(.secondary)
                    }
                    if shouldShowBasePreview {
                        HStack {
                            Text(String(localized: "account.balance.approxInBase"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(basePreview)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "account.balance"))
                } footer: {
                    // ADR-001: amount field is always in account.currency. No
                    // FX at save time. Display-only preview in base currency
                    // appears above when the two differ.
                    Text(String(localized: "account.balance.hint"))
                        .font(.caption)
                }

                Section {
                    ForEach(CurrencyCode.allCases, id: \.self) { currency in
                        Button {
                            selectedCurrency = currency
                        } label: {
                            HStack {
                                Text(currency.symbol)
                                    .font(.title3)
                                    .frame(width: 30)
                                Text(currency.name)
                                    .foregroundStyle(isCurrencyLocked ? .secondary : .primary)
                                Spacer()
                                if selectedCurrency == currency {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accent)
                                }
                            }
                        }
                        .disabled(isCurrencyLocked)
                    }
                } header: {
                    Text(String(localized: "settings.currency"))
                } footer: {
                    if isCurrencyLocked {
                        // ADR-001: changing `account.currency` while the
                        // account still has rows would leave every
                        // `tx.amount_native` in the OLD currency while the
                        // account is now in a new one — producing the
                        // VND-as-RUB phantom on history. Block at the UI.
                        Text(String(localized: "account.currency.locked.hint"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section(String(localized: "categories.icon")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Text(icon)
                                .font(.title)
                                .frame(width: 48, height: 48)
                                .background(selectedIcon == icon ? Color(hex: selectedColor).opacity(0.3) : .clear)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(selectedIcon == icon ? Color(hex: selectedColor) : .clear, lineWidth: 2) }
                                .onTapGesture { selectedIcon = icon }
                        }
                    }
                }

                Section(String(localized: "categories.color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedColor == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { selectedColor = color }
                        }
                    }
                }

                // Shared-account management — only for existing accounts.
                // Routes into ShareAccountView which exposes invite flow +
                // per-member split weights (used by settlement). We show it
                // unconditionally for edit mode; ShareAccountView itself
                // handles the "no members yet" case gracefully.
                if isEditing, let acc = editingAccount {
                    Section(String(localized: "account.sharing.section")) {
                        Button {
                            showShareSheet = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.2.fill")
                                    .foregroundStyle(Color.accent)
                                    .frame(width: 28, height: 28)
                                    .background(Color.accent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "account.sharing.membersAndSplits"))
                                        .foregroundStyle(.primary)
                                    Text(String(localized: "account.sharing.membersAndSplits.subtitle"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showShareSheet) {
                            ShareAccountView(account: acc)
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

                if let acc = editingAccount {
                    // Destructive action — separate section at the bottom so
                    // it's visually far from Save. `DELETE FROM accounts`
                    // cascades into transactions (migration 20260422160000),
                    // which is exactly what the confirmation text promises.
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text(String(localized: "account.deleteAccount"))
                            }
                        }
                        .disabled(isDeleting || isSaving)
                    }
                    .confirmationDialog(
                        String(localized: "account.deleteConfirm.title"),
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "account.deleteConfirm.action"), role: .destructive) {
                            Task { await deleteAccount(acc) }
                        }
                        Button(String(localized: "common.cancel"), role: .cancel) { }
                    } message: {
                        let count = txCountForAccount(acc)
                        if count > 0 {
                            Text(String(
                                format: String(localized: "account.deleteConfirm.withTx %lld"),
                                count
                            ))
                        } else {
                            Text(String(localized: "account.deleteConfirm.empty"))
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "account.edit") : String(localized: "account.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "common.save") : String(localized: "common.create")) {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .onAppear { prefill() }
        }
    }

    // MARK: - Preview (base currency approx)

    /// Currency picker is locked in edit mode whenever the account has
    /// at least one transaction. Changing `account.currency` under a
    /// populated account silently mis-denominates the entire history —
    /// see Scenario 7 in `project_multi_currency_plan.md`. Fresh accounts
    /// and account creation are unaffected.
    private var isCurrencyLocked: Bool {
        guard let account = editingAccount else { return false }
        return appViewModel.dataStore.transactions.contains { $0.accountId == account.id }
    }

    /// Only show the base-currency preview when the user's base differs from
    /// the account's currency. Avoids redundant "≈ 100 ₽" under "100 ₽".
    private var shouldShowBasePreview: Bool {
        let base = appViewModel.currencyManager.dataCurrency
        return base != selectedCurrency && parsedBalance != nil
    }

    private var parsedBalance: Double? {
        let raw = initialBalanceText.replacingOccurrences(of: ",", with: ".")
        return Double(raw)
    }

    private var basePreview: String {
        guard let parsed = parsedBalance else { return "" }
        // FX: account currency → base currency.
        let cm = appViewModel.currencyManager
        let baseCode = cm.dataCurrency.rawValue.uppercased()
        let fromCode = selectedCurrency.rawValue.uppercased()
        let kopecks = Int64((parsed * 100).rounded())
        let fxRates = cm.rates.mapValues { Decimal($0) }
        let converted = NetWorthCalculator.convert(
            amount: kopecks,
            from: fromCode,
            to: baseCode,
            rates: fxRates
        )
        let display = Decimal(converted) / 100
        return "≈ \(cm.formatInCurrency(display, currency: cm.dataCurrency))"
    }

    // MARK: - Prefill

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        selectedIcon = account.icon
        selectedColor = account.color
        selectedCurrency = account.currencyCode

        // ADR-001: balance(for:) is already in account.currency (kopecks).
        // The old implementation ran it through `baseToAccount`, which
        // double-converted on non-RUB accounts and produced nonsense.
        let kopecksInAccountCurrency = appViewModel.dataStore.balance(for: account)
        let value = Double(kopecksInAccountCurrency) / 100.0
        let rounded = (value * 100).rounded() / 100
        initialBalanceText = rounded == rounded.rounded()
            ? "\(Int(rounded))"
            : String(format: "%.2f", rounded)
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        do {
            // ADR-001: `initialBalanceText` is ALWAYS in `selectedCurrency`.
            // No FX conversion — the field label already shows the account's
            // own symbol.
            let parsed = Double(initialBalanceText.replacingOccurrences(of: ",", with: ".")) ?? 0
            let enteredKopecks = Int64((parsed * 100).rounded())

            if let account = editingAccount {
                // The user typed the DESIRED total balance. We back into
                // `initial_balance` by subtracting the net of all
                // transactions (which are already in account currency via
                // `amountNative` after ADR-001).
                let net = accountNet(for: account)
                let newInitial = enteredKopecks - net
                let newBalance: Int64? = newInitial != account.initialBalance ? newInitial : nil
                try await accountRepo.update(
                    id: account.id,
                    name: name,
                    icon: selectedIcon,
                    color: selectedColor,
                    currency: selectedCurrency.rawValue.lowercased(),
                    initialBalance: newBalance
                )
            } else {
                // New account: entered value IS the initial balance in
                // account currency.
                _ = try await accountRepo.create(
                    name: name,
                    icon: selectedIcon,
                    color: selectedColor,
                    initialBalance: enteredKopecks,
                    currency: selectedCurrency.rawValue.lowercased()
                )
                AnalyticsService.logCreateAccount()
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    /// Net of all transactions on this account — in the account's currency
    /// (because `amountNative` is by definition in that currency per ADR-001).
    private func accountNet(for account: Account) -> Int64 {
        var net: Int64 = 0
        for tx in appViewModel.dataStore.transactions {
            guard tx.accountId == account.id else { continue }
            if tx.type == .income { net += tx.amountNative }
            else if tx.type == .expense { net -= tx.amountNative }
        }
        return net
    }

    // MARK: - Delete

    /// Number of transactions that will be removed by the CASCADE FK
    /// when this account is deleted. Surfaced in the confirmation
    /// dialog so the user sees the real cost.
    private func txCountForAccount(_ account: Account) -> Int {
        appViewModel.dataStore.transactions.filter { $0.accountId == account.id }.count
    }

    private func deleteAccount(_ account: Account) async {
        isDeleting = true
        do {
            try await accountRepo.delete(id: account.id)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeleting = false
    }
}
