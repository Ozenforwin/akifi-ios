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
    /// True once the user manually picked a currency in the form's picker.
    /// Prevents account-change auto-sync from overriding their explicit choice.
    @State private var userPickedCurrency = false

    // MARK: - Large-expense confirmation state

    /// Drives the "Confirm large expense" alert. Set right before save
    /// when `TransactionGuards.shouldConfirmLargeExpense` returns true;
    /// cleared on either alert button.
    @State private var showLargeExpenseAlert = false
    /// Cached decision so the alert message can render the median
    /// without recomputing. Re-set every time we open the alert.
    @State private var largeExpenseDecision: TransactionGuards.LargeExpenseDecision?
    /// Snapshot of the editing transaction's original amount/currency
    /// pair, captured in `prefillIfEditing`. Used to skip the alert when
    /// the user opens an existing transaction and saves without changing
    /// either field — we don't want to nag on accidental "Update" taps.
    @State private var editingBaselineAmount: Decimal?
    @State private var editingBaselineCurrency: CurrencyCode?

    // Payment source state
    /// Selected source account. `nil` means "same as target" (regular expense, no auto-transfer).
    @State private var selectedPaymentSourceId: String?
    /// `accountId → defaultSourceId` loaded from `user_account_defaults` on appear.
    @State private var userDefaults: [String: String] = [:]
    private let defaultsRepo = UserAccountDefaultsRepository()

    /// Per-target-account flag: was the onboarding banner acknowledged?
    /// Keyed by `paymentSource.onboardingSeen.<accountId>` in UserDefaults.
    @State private var onboardingDismissedAccounts: Set<String> = []

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

    init(categories: [Category], accounts: [Account], editingTransaction: Transaction? = nil, defaultType: TransactionType? = nil, defaultCategoryId: String? = nil, defaultAccountId: String? = nil, onSave: @escaping () async -> Void) {
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
        // Pre-select the account (e.g. when the FAB is opened from a
        // specific Home-carousel account or the shared-account detail
        // screen). Editing flow ignores this — the row already carries
        // its own `accountId`, prefilled in `prefillIfEditing()`.
        // The matching currency is picked up automatically via the same
        // `prefillIfEditing()` path on `.onAppear`.
        if let defaultAccountId, editingTransaction == nil,
           accounts.contains(where: { $0.id == defaultAccountId }) {
            _selectedAccountId = State(initialValue: defaultAccountId)
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

    /// Eligible source accounts for the picker — own accounts, regardless
    /// of currency. Always includes the target itself as "this account".
    /// Cross-currency sources are fine — the `create_expense_with_auto_transfer`
    /// 10-arg RPC overload handles FX by recording the transfer-out leg in
    /// the source's currency while the expense + transfer-in stay in target's.
    private var eligibleSources: [Account] {
        guard let target = selectedAccount, let uid = currentUserId else { return [] }
        return accounts.filter { acc in
            acc.userId == uid && acc.id != target.id
        }
    }

    /// True if the payment-source picker should be shown at all. Surfaces
    /// for expenses on a shared target account with at least one eligible
    /// personal source. In edit mode we still show it — the save path
    /// detects a source change and re-creates the auto-transfer triplet
    /// (delete old + create new) so the DB stays consistent.
    ///
    /// Edge case: when editing a transfer-leg (not the main expense row)
    /// we hide the picker — the user can't meaningfully "change the
    /// source" of a transfer leg, and reassigning requires the main
    /// expense id.
    private var shouldShowPaymentSource: Bool {
        guard selectedType == .expense && targetIsShared && !eligibleSources.isEmpty else {
            return false
        }
        if let tx = editingTransaction, tx.isAutoTransferLeg {
            return false
        }
        return true
    }

    /// Currency mismatch is no longer a reason to disable the picker —
    /// the RPC accepts cross-currency sources. Kept as `false` so the
    /// rest of the UI code can stay structurally identical; we may reuse
    /// this flag if we add future restrictions.
    private var paymentSourceDisabled: Bool { false }

    /// Decorates the source-account row in the picker. Cross-currency is
    /// relative to what the user actually *entered* (`selectedCurrency`) —
    /// not the target account's default currency. Otherwise picking a USD
    /// source while the user entered the transaction in USD would trigger
    /// a pointless "(100 $ ≈ 100 $)" FX preview just because the target
    /// account happens to be RUB.
    private func paymentSourceLabel(for acc: Account) -> String {
        let starred = userDefaults[selectedAccountId ?? ""] == acc.id
        let starSuffix = starred ? " ⭐" : ""
        // Source matches what the user typed in → no conversion, clean label.
        if acc.currency.lowercased() == selectedCurrency.rawValue.lowercased() {
            return "\(acc.icon) \(acc.name)\(starSuffix)"
        }
        // Cross-currency — source account uses a different currency than
        // what the user entered. Show the converted amount in brackets.
        let amountValue = calculatorState.getResult() ?? 0
        let sourceAmount = Self.crossConvert(
            amount: amountValue,
            from: selectedCurrency,
            to: acc.currencyCode,
            using: appViewModel.currencyManager
        )
        let sourceStr = Self.formatRawAmount(sourceAmount, currency: acc.currencyCode)
        return "\(acc.icon) \(acc.name) (≈ \(sourceStr))\(starSuffix)"
    }

    /// True iff the currently-selected source uses a different currency
    /// than the user-entered amount. Drives the two-line hint and the
    /// RPC routing (10-arg overload vs 8-arg).
    private var isCrossCurrencySelection: Bool {
        guard let sourceId = selectedPaymentSourceId,
              let source = accounts.first(where: { $0.id == sourceId })
        else { return false }
        return source.currency.lowercased() != selectedCurrency.rawValue.lowercased()
    }

    /// Whether to surface the first-time onboarding banner. Fires only
    /// when every stronger signal is absent:
    /// - we're creating (not editing) an expense,
    /// - target is shared,
    /// - there's at least one own personal account available as source,
    /// - the user has NOT already saved a default for this target,
    /// - they haven't already dismissed this banner for this target.
    private var shouldShowOnboardingBanner: Bool {
        guard shouldShowPaymentSource else { return false }
        guard let targetId = selectedAccountId else { return false }
        if userDefaults[targetId] != nil { return false }
        if onboardingDismissedAccounts.contains(targetId) { return false }
        return true
    }

    private static func onboardingKey(_ accountId: String) -> String {
        "paymentSource.onboardingSeen.\(accountId)"
    }

    /// Persist "dismissed" for this account so the banner doesn't come
    /// back next time the user opens the form on the same target.
    private func dismissOnboarding() {
        guard let targetId = selectedAccountId else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingKey(targetId))
        onboardingDismissedAccounts.insert(targetId)
        HapticManager.light()
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
                    amountSectionContent
                }

                if !accounts.isEmpty {
                    Section(String(localized: "common.account")) {
                        Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                            Text(String(localized: "transaction.noAccount")).tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                        .onChange(of: selectedAccountId) { _, newId in
                            // Pre-select the user's saved default source for
                            // the new target account. The ⭐ badge still marks
                            // the default in the picker, and the user can
                            // override at any time. Edit mode is handled by
                            // prefillIfEditing — don't clobber it here.
                            if !isEditing {
                                selectedPaymentSourceId = newId.flatMap { userDefaults[$0] }
                            }
                            // Auto-sync entry currency to the account's currency
                            // unless the user has manually picked a currency.
                            // Without this, a default selectedCurrency=.rub on a
                            // VND account caused 2M VND → 26277 USD save bugs.
                            if !userPickedCurrency, !isEditing,
                               let id = newId,
                               let acc = accounts.first(where: { $0.id == id }) {
                                selectedCurrency = acc.currencyCode
                            }
                        }
                    }
                }

                if shouldShowOnboardingBanner {
                    onboardingBannerSection
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
            .onChange(of: selectedPaymentSourceId) { _, newValue in
                // First time the user explicitly picks a source counts as
                // "onboarded" — no need to keep nagging. `nil` = "this account"
                // default and doesn't count as explicit engagement.
                if newValue != nil {
                    dismissOnboarding()
                }
            }
            .onChange(of: selectedCurrency) { _, _ in
                // Mark the choice as explicit so onChange(selectedAccountId)
                // stops overriding it. Only matters for new transactions —
                // editing flows route through prefillIfEditing.
                if !isEditing { userPickedCurrency = true }
            }
            .alert(
                String(localized: "transaction.confirmLargeExpense.title"),
                isPresented: $showLargeExpenseAlert,
                presenting: largeExpenseDecision
            ) { _ in
                Button(String(localized: "transaction.confirmLargeExpense.confirm"), role: .destructive) {
                    Task { await performSave() }
                }
                Button(String(localized: "transaction.confirmLargeExpense.cancel"), role: .cancel) {
                    // Stay on the form so the user can fix the amount or
                    // currency. No state mutation needed — `isLoading`
                    // was never set, the `.disabled` Save button will
                    // re-enable as soon as the alert dismisses.
                }
            } message: { decision in
                Text(largeExpenseAlertMessage(for: decision))
            }
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

    // MARK: - Onboarding banner (first-time Payment-Source discovery)

    /// Light teaching moment for users who land on a shared-account expense
    /// form and haven't yet discovered the "Paid from" feature. Self-
    /// dismissing on first interaction — either Understood tap, or first
    /// explicit source pick via the picker itself.
    @ViewBuilder
    private var onboardingBannerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accent.opacity(0.25), Color.accent.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "tx.paymentSource.onboarding.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "tx.paymentSource.onboarding.body"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Button {
                    dismissOnboarding()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "tx.paymentSource.onboarding.dismiss"))
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(
            LinearGradient(
                colors: [Color.accent.opacity(0.09), Color.accent.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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

            if let sourceId = selectedPaymentSourceId,
               let source = accounts.first(where: { $0.id == sourceId }),
               let target = selectedAccount {
                hintBubble(source: source, target: target)
            }
        }
    }

    /// Live preview text rendered as an accent-tinted bubble. Split out so
    /// the parent `@ViewBuilder` doesn't have to host imperative `let`
    /// bindings alongside View statements.
    @ViewBuilder
    private func hintBubble(source: Account, target: Account) -> some View {
        let amountValue = calculatorState.getResult() ?? 0
        let targetStr = Self.formatRawAmount(amountValue, currency: selectedCurrency)
        let hint = buildHint(source: source, target: target, amount: amountValue, targetStr: targetStr)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accent)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accent.opacity(0.22), lineWidth: 0.5)
        )
    }

    // MARK: - Amount section (calculator + currency chip)

    /// Stacked layout: calculator on top, currency chip pinned to the
    /// right edge directly under it. Visually anchors "this number is
    /// in *this* currency" so the user can't miss the unit before
    /// hitting Save — the bug class this whole feature exists to
    /// prevent (entering 350 000 ₽ on a VND account).
    @ViewBuilder
    private var amountSectionContent: some View {
        VStack(spacing: 12) {
            CalculatorKeyboardView(state: calculatorState)

            HStack(spacing: 8) {
                Spacer()
                currencyChip
                if shouldShowAccountFXPreview {
                    Text(accountFXPreviewText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
    }

    /// Tappable chip that opens a `Menu` over `CurrencyCode.allCases`.
    /// Uses an accent-tinted border so it reads as an interactive
    /// affordance, not a passive label — the prior inline `Picker`
    /// blended into the secondary row text and got ignored.
    @ViewBuilder
    private var currencyChip: some View {
        Menu {
            ForEach(CurrencyCode.allCases, id: \.self) { code in
                Button {
                    selectedCurrency = code
                } label: {
                    if code == selectedCurrency {
                        Label("\(code.symbol) \(code.name)", systemImage: "checkmark")
                    } else {
                        Text("\(code.symbol) \(code.name)")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedCurrency.symbol)
                    .font(.headline.weight(.semibold))
                Text(selectedCurrency.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .monospaced()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accent.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .accessibilityLabel(String(localized: "common.currency"))
        .accessibilityValue("\(selectedCurrency.symbol) \(selectedCurrency.name)")
    }

    /// True when we should render the small "≈ 1 900 ₽" preview next
    /// to the chip — only when the user's entry currency differs from
    /// the selected account's currency. Re-uses the existing
    /// `crossConvert` helper for consistency with the payment-source
    /// hint label.
    private var shouldShowAccountFXPreview: Bool {
        guard let acc = selectedAccount else { return false }
        guard acc.currencyCode != selectedCurrency else { return false }
        guard let result = calculatorState.getResult(), result > 0 else {
            return false
        }
        // Need a rate in both directions; otherwise crossConvert returns
        // the input unchanged and we'd show "≈ 350 000 ₽" for "350 000 ₫".
        let cm = appViewModel.currencyManager
        return cm.rates[selectedCurrency.rawValue].map { $0 > 0 } ?? false
            && cm.rates[acc.currency.uppercased()].map { $0 > 0 } ?? false
    }

    private var accountFXPreviewText: String {
        guard let acc = selectedAccount,
              let amount = calculatorState.getResult() else { return "" }
        let converted = Self.crossConvert(
            amount: amount,
            from: selectedCurrency,
            to: acc.currencyCode,
            using: appViewModel.currencyManager
        )
        return "≈ \(Self.formatRawAmount(converted, currency: acc.currencyCode))"
    }

    // MARK: - Large-expense alert message

    /// Renders the second line of the confirmation alert, e.g.:
    ///   "It's 350 000 ₫. You usually spend about 1 900 ₽ at a time."
    /// The user-entered figure is formatted in the **input currency**
    /// (so they can sanity-check the unit they actually typed), while
    /// the median is in base currency (the only one we have a stable
    /// reference for).
    private func largeExpenseAlertMessage(
        for decision: TransactionGuards.LargeExpenseDecision
    ) -> String {
        let input = calculatorState.getResult() ?? 0
        let inputStr = Self.formatRawAmount(input, currency: selectedCurrency)
        let baseCode = appViewModel.currencyManager.dataCurrency
        let medianStr = appViewModel.currencyManager.formatInCurrency(
            decision.medianInBaseDisplay,
            currency: baseCode
        )
        return String(
            format: String(localized: "transaction.confirmLargeExpense.message"),
            inputStr,
            medianStr
        )
    }

    private func buildHint(source: Account, target: Account, amount: Decimal, targetStr: String) -> String {
        // "Cross-currency" is relative to what the user entered, not the
        // target's native currency. Keeps the hint quiet when source +
        // entered currency match (e.g. entered 100 $, picked USD source).
        if source.currency.lowercased() != selectedCurrency.rawValue.lowercased() {
            let sourceAmount = Self.crossConvert(
                amount: amount,
                from: selectedCurrency,
                to: source.currencyCode,
                using: appViewModel.currencyManager
            )
            let sourceStr = Self.formatRawAmount(sourceAmount, currency: source.currencyCode)
            return String(format: String(localized: "tx.paymentSource.hint.autoTransfer.crossCurrency"),
                          sourceStr, source.name, targetStr, target.name)
        }
        return String(format: String(localized: "tx.paymentSource.hint.autoTransfer"),
                      targetStr, source.name, target.name)
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
            // Pre-select the saved default for the currently-targeted account
            // on a fresh form. `onChange(of: selectedAccountId)` covers
            // subsequent target switches; this branch handles the initial
            // load when the account was set before the defaults arrived.
            // Edit mode keeps the row's stored source — don't override.
            if !isEditing, selectedPaymentSourceId == nil,
               let accId = selectedAccountId,
               let defaultSrc = map[accId] {
                selectedPaymentSourceId = defaultSrc
            }
        } catch {
            // Silent — defaults are optional UX.
            AppLogger.data.debug("paymentDefaults load: \(error.localizedDescription)")
        }

        // Hydrate onboarding-dismissed flags from UserDefaults. We only
        // care about the accounts the user is likely to see this session,
        // so we scan every account and check the per-id key.
        var seen: Set<String> = []
        for acc in accounts {
            if UserDefaults.standard.bool(forKey: Self.onboardingKey(acc.id)) {
                seen.insert(acc.id)
            }
        }
        onboardingDismissedAccounts = seen
    }

    private func prefillIfEditing() {
        guard let tx = editingTransaction else {
            // New transaction: prefer the currency of the pre-selected account
            // (e.g. when opened from a specific account screen) so the user
            // doesn't accidentally enter a VND amount as RUB on a VND account.
            // Falls back to the user's display preference only when no account
            // is selected yet.
            if let accId = selectedAccountId,
               let acc = accounts.first(where: { $0.id == accId }) {
                selectedCurrency = acc.currencyCode
            } else {
                selectedCurrency = appViewModel.currencyManager.selectedCurrency
            }
            return
        }

        // ADR-001 prefill rules:
        // 1. If the row has `foreignCurrency` set (new multi-currency row),
        //    show the original user-entered value in the foreign currency.
        // 2. Else — show `amountNative` in the account's currency (which
        //    falls back to `amount` for pre-Phase-1 rows, by Transaction
        //    decoder contract).
        if let fc = tx.foreignCurrency,
           let code = CurrencyCode(rawValue: fc.uppercased()),
           let fa = tx.foreignAmount {
            selectedCurrency = code
            calculatorState.setValue(fa)
        } else {
            // Account currency — look up from the live accounts list.
            let account = accounts.first(where: { $0.id == tx.accountId })
            let ccyCode = account?.currencyCode ?? appViewModel.currencyManager.dataCurrency
            selectedCurrency = ccyCode
            calculatorState.setValue(tx.amountNative.displayAmount)
        }

        description = tx.description ?? ""
        selectedType = tx.type
        selectedCategoryId = tx.categoryId
        selectedAccountId = tx.accountId
        selectedPaymentSourceId = tx.paymentSourceAccountId
        if let txDate = Self.isoDateTimeFormatter.date(from: tx.rawDateTime) ?? Self.isoDateFormatter.date(from: tx.date) {
            date = txDate
        }

        // Snapshot the as-loaded amount and currency. The large-expense
        // alert compares against this on save and skips the prompt when
        // neither value changed — the user just opened an existing row
        // to tweak the description / category and shouldn't be nagged.
        editingBaselineAmount = calculatorState.getResult()
        editingBaselineCurrency = selectedCurrency
    }

    // MARK: - Save

    /// Toolbar entry point. Validates the amount, runs the
    /// large-expense guard, and either presents the confirmation
    /// alert or jumps straight to `performSave()`. Side-effect-free
    /// when the alert is shown — the actual write happens in the
    /// alert's "Confirm" button handler.
    private func save() async {
        guard let amountValue = calculatorState.getResult(), amountValue > 0 else {
            errorMessage = String(localized: "transaction.invalidAmount")
            return
        }

        // Skip the guard when editing an existing row and neither the
        // amount nor the currency changed — typical "fix typo in
        // description" workflow shouldn't pop a destructive alert.
        let amountUnchanged: Bool = {
            guard isEditing else { return false }
            guard let baselineAmount = editingBaselineAmount,
                  let baselineCurrency = editingBaselineCurrency else {
                return false
            }
            return baselineAmount == amountValue && baselineCurrency == selectedCurrency
        }()

        if !amountUnchanged {
            let decision = TransactionGuards.shouldConfirmLargeExpense(
                inputAmount: amountValue,
                inputCurrency: selectedCurrency.rawValue,
                type: selectedType,
                allTransactions: appViewModel.dataStore.transactions,
                context: appViewModel.dataStore.currencyContext
            )
            if decision.shouldConfirm {
                largeExpenseDecision = decision
                showLargeExpenseAlert = true
                return
            }
        }

        await performSave()
    }

    /// Actual write path. Invoked either directly from `save()` (when
    /// the guard passes) or from the alert's confirm button. All the
    /// previous `save()` logic lives here verbatim — the split is
    /// purely about gating, not behavior.
    private func performSave() async {
        guard let amountValue = calculatorState.getResult(), amountValue > 0 else {
            errorMessage = String(localized: "transaction.invalidAmount")
            return
        }

        isLoading = true
        let dateStr = Self.isoDateTimeFormatter.string(from: date)

        // ADR-001: the ONLY canonical amount is in the owning account's
        // currency. Foreign entry is decomposed into:
        //   amount_native    = amountValue * FX(selectedCurrency → account)
        //   foreign_amount   = amountValue (original)
        //   foreign_currency = selectedCurrency
        //   fx_rate          = amount_native / foreign_amount
        // When selectedCurrency == account.currency we skip foreign_* fields
        // entirely — the row is a "native" entry.
        let cm = appViewModel.currencyManager
        let accountCode: CurrencyCode = selectedAccount?.currencyCode ?? cm.dataCurrency
        let amountInAccountCurrency: Decimal
        let foreignAmount: Decimal?
        let foreignCurrencyCode: String?
        let fxRate: Decimal?
        if selectedCurrency == accountCode {
            amountInAccountCurrency = amountValue
            foreignAmount = nil
            foreignCurrencyCode = nil
            fxRate = nil
        } else {
            amountInAccountCurrency = Self.crossConvert(
                amount: amountValue,
                from: selectedCurrency,
                to: accountCode,
                using: cm
            )
            foreignAmount = amountValue
            foreignCurrencyCode = selectedCurrency.rawValue
            fxRate = amountValue != 0
                ? (amountInAccountCurrency / amountValue)
                : nil
        }

        // Legacy `currency` column now always mirrors account.currency on
        // new writes. The foreign-entry currency lives in `foreign_currency`.
        let txCurrencyLabel = accountCode.rawValue

        do {
            // Always source user_id from the live Supabase session.
            // `dataStore.profile?.id` can be stale right after sign-in or
            // token refresh, and mismatch → RLS violation on INSERT.
            let userId = try await SupabaseManager.shared.currentUserId()
            if let tx = editingTransaction {
                // Determine whether the payment source has changed relative
                // to what the DB row currently stores. The picker emits nil
                // for "this account" and a source id otherwise.
                let previousSource = tx.paymentSourceAccountId
                let resolvedNewSource: String? = {
                    guard selectedType == .expense,
                          let sourceId = selectedPaymentSourceId,
                          sourceId != selectedAccountId
                    else { return nil }
                    return sourceId
                }()
                let sourceChanged = previousSource != resolvedNewSource
                let isMainExpense = tx.type == .expense && tx.transferGroupId == nil

                // Reassignment path: only fires for the main expense row when
                // the user actually changed the source. Covers the four
                // scenarios from the spec:
                //   A. auto-transfer → simple expense (newSource = nil)
                //   B. simple expense → auto-transfer (oldSource = nil)
                //   C. auto-transfer source A → B (both non-nil, differ)
                //   D. unchanged → fall through to the plain update RPC
                // Implementation is client-side delete + recreate; not
                // atomic, but the window is < ~300ms and the failure mode
                // (delete succeeds, create fails) leaves the user without
                // the expense — recoverable by retry. An RPC-level wrapper
                // is tracked for a future migration.
                if sourceChanged && isMainExpense {
                    try await reassignExpenseSource(
                        tx: tx,
                        amountInAccountCurrency: amountInAccountCurrency,
                        foreignAmount: foreignAmount,
                        foreignCurrencyCode: foreignCurrencyCode,
                        fxRate: fxRate,
                        currencyLabel: txCurrencyLabel,
                        userId: userId,
                        dateStr: dateStr,
                        newSource: resolvedNewSource
                    )
                } else {
                    // Route through auto-transfer update RPC only when this is
                    // an expense with an existing auto_transfer_group_id and no
                    // transfer_group_id (i.e. it's the main expense row, not a
                    // transfer leg) AND the source hasn't changed.
                    let useAutoUpdate = tx.type == .expense
                        && tx.autoTransferGroupId != nil
                        && tx.transferGroupId == nil
                    // Pass account_id only when it actually changed — avoids
                    // accidentally blanking it, and matches legacy "only
                    // update dirty fields" behavior.
                    let accountIdForUpdate: String? = selectedAccountId != tx.accountId
                        ? selectedAccountId
                        : nil
                    let input = UpdateTransactionInput(
                        amount: amountInAccountCurrency,
                        amount_native: amountInAccountCurrency,
                        currency: txCurrencyLabel,
                        foreign_amount: foreignAmount,
                        foreign_currency: foreignCurrencyCode,
                        fx_rate: fxRate,
                        type: selectedType.rawValue,
                        date: dateStr,
                        description: description.isEmpty ? nil : description,
                        category_id: selectedCategoryId,
                        merchant_name: nil,
                        account_id: accountIdForUpdate,
                        useAutoTransferUpdate: useAutoUpdate,
                        // Form save replaces ALL currency-related columns —
                        // switching from VND back to the account currency
                        // must clear foreign_*, not silently leave them.
                        replaceCurrencyFields: true
                    )
                    try await appViewModel.dataStore.updateTransaction(id: tx.id, input)
                }
            } else {
                // Resolve payment source — only record it when target is shared AND source != target.
                let resolvedPaymentSource: String? = {
                    guard selectedType == .expense,
                          let sourceId = selectedPaymentSourceId,
                          sourceId != selectedAccountId
                    else { return nil }
                    return sourceId
                }()
                // Cross-currency: when the source account uses a different
                // currency than the TARGET account, convert the target-currency
                // amount into the source's currency for the transfer-out leg.
                // This is independent of the user's entry currency — ADR-001
                // already normalized to `amountInAccountCurrency` above.
                var sourceAmount: Decimal? = nil
                var sourceCurrency: String? = nil
                if let srcId = resolvedPaymentSource,
                   let src = accounts.first(where: { $0.id == srcId }),
                   src.currency.lowercased() != accountCode.rawValue.lowercased() {
                    let srcCode = src.currencyCode
                    sourceAmount = Self.crossConvert(
                        amount: amountInAccountCurrency,
                        from: accountCode,
                        to: srcCode,
                        using: cm
                    )
                    sourceCurrency = srcCode.rawValue
                }
                let input = CreateTransactionInput(
                    user_id: userId,
                    account_id: selectedAccountId,
                    amount: amountInAccountCurrency,
                    amount_native: amountInAccountCurrency,
                    currency: txCurrencyLabel,
                    foreign_amount: foreignAmount,
                    foreign_currency: foreignCurrencyCode,
                    fx_rate: fxRate,
                    type: selectedType.rawValue,
                    date: dateStr,
                    description: description.isEmpty ? nil : description,
                    category_id: selectedCategoryId,
                    merchant_name: nil,
                    payment_source_account_id: resolvedPaymentSource,
                    source_amount: sourceAmount,
                    source_currency: sourceCurrency
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

    /// Client-side payment-source reassignment when editing an existing
    /// expense. Drops the old triplet (or plain expense row) and recreates
    /// the new shape. Not atomic — see the call site note. Category /
    /// description / merchant are preserved from the form state.
    private func reassignExpenseSource(
        tx: Transaction,
        amountInAccountCurrency: Decimal,
        foreignAmount: Decimal?,
        foreignCurrencyCode: String?,
        fxRate: Decimal?,
        currencyLabel: String,
        userId: String,
        dateStr: String,
        newSource: String?
    ) async throws {
        // 1. Delete the old row. `DataStore.deleteTransaction` routes
        //    through `delete_expense_with_auto_transfer` when the row has
        //    `auto_transfer_group_id` set, removing all three rows
        //    atomically. For a plain expense it's a single delete.
        //    The method swallows its own errors and reports them through
        //    `dataStore.error`; we re-throw upstream if that field
        //    surfaces a fresh message.
        let priorError = appViewModel.dataStore.error
        await appViewModel.dataStore.deleteTransaction(tx)
        if let err = appViewModel.dataStore.error, err != priorError {
            throw NSError(
                domain: "TransactionFormView.reassign", code: -1,
                userInfo: [NSLocalizedDescriptionKey: err]
            )
        }

        // 2. Rebuild the cross-currency source amount if needed. Uses the
        //    target account's currency (ADR-001) as the reference, not the
        //    user's entry currency — the RPC expects the transfer-out leg
        //    expressed in the source's own currency.
        let cm = appViewModel.currencyManager
        let targetCode: CurrencyCode = selectedAccount?.currencyCode ?? cm.dataCurrency
        var sourceAmount: Decimal? = nil
        var sourceCurrency: String? = nil
        if let srcId = newSource,
           let src = accounts.first(where: { $0.id == srcId }),
           src.currency.lowercased() != targetCode.rawValue.lowercased() {
            let srcCode = src.currencyCode
            sourceAmount = Self.crossConvert(
                amount: amountInAccountCurrency,
                from: targetCode,
                to: srcCode,
                using: cm
            )
            sourceCurrency = srcCode.rawValue
        }

        // 3. Recreate with the new shape. `addTransaction` will route to
        //    `create_expense_with_auto_transfer` when `newSource != nil`
        //    and `newSource != accountId`, or to a plain INSERT otherwise.
        let input = CreateTransactionInput(
            user_id: userId,
            account_id: selectedAccountId,
            amount: amountInAccountCurrency,
            amount_native: amountInAccountCurrency,
            currency: currencyLabel,
            foreign_amount: foreignAmount,
            foreign_currency: foreignCurrencyCode,
            fx_rate: fxRate,
            type: selectedType.rawValue,
            date: dateStr,
            description: description.isEmpty ? nil : description,
            category_id: selectedCategoryId,
            merchant_name: nil,
            payment_source_account_id: newSource,
            source_amount: sourceAmount,
            source_currency: sourceCurrency
        )
        _ = try await appViewModel.dataStore.addTransaction(input)

        // 4. Update saved default to reflect the user's new preference.
        if let targetId = selectedAccountId,
           let newSource,
           userDefaults[targetId] != newSource {
            Task.detached(priority: .background) { [defaultsRepo] in
                try? await defaultsRepo.upsert(accountId: targetId, defaultSourceId: newSource)
            }
            userDefaults[targetId] = newSource
        }
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

    /// Convert an amount between two arbitrary currencies using the rate
    /// table inside `CurrencyManager`. The rates are USD-based, so
    /// `amount_to = amount_from / rate[from] * rate[to]`. Used for the
    /// cross-currency picker hint and for the RPC `p_source_amount` leg.
    @MainActor
    /// Cross-currency conversion. Returns the input unchanged when either
    /// rate is missing — coercing to 1.0 is what produced the 2 000 000 VND
    /// → 26 315 USD save bug (rates["VND"] was absent from fallbackRates,
    /// fixed in 2026-04-19). The form's UI has a separate FX-preview that
    /// flags missing rates; the Save action is now a no-op rather than a
    /// silent corruption.
    static func crossConvert(
        amount: Decimal,
        from: CurrencyCode,
        to: CurrencyCode,
        using cm: CurrencyManager
    ) -> Decimal {
        guard from != to else { return amount }
        guard let fromRate = cm.rates[from.rawValue], fromRate > 0,
              let toRate   = cm.rates[to.rawValue],   toRate > 0 else {
            return amount
        }
        return amount / Decimal(fromRate) * Decimal(toRate)
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
