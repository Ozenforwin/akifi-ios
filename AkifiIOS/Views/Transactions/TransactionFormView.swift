import SwiftUI
import Supabase

/// Values a NEW transaction form opens with — the quick-entry draft behind
/// «Подробнее». Editing an existing row ignores it.
struct TransactionFormPrefill: Equatable, Sendable {
    var type: TransactionType
    /// Main units of `currencyCode` (or of the account currency).
    var amount: Decimal?
    /// Set only when the entry currency differs from the account's (the
    /// phrase said «€20»); the form keeps it as the user's pick.
    var currencyCode: String?
    var accountId: String?
    var categoryId: String?
    var date: Date
    var description: String
}

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
    /// Entry currency + "the user picked it" (M4). Programmatic sync goes
    /// through `follow` / `load`; only the picker's setter calls
    /// `userSelected`.
    @State private var entryCurrency = EntryCurrencyState(.rub)
    private var selectedCurrency: CurrencyCode { entryCurrency.currency }
    /// The picker's binding — the one place a choice counts as the user's.
    private var currencyPickerSelection: Binding<CurrencyCode> {
        Binding(
            get: { entryCurrency.currency },
            set: { entryCurrency.userSelected($0) }
        )
    }

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

    // Personal spending on a shared account (1.6.0, contract §B3).
    @State private var personalDebtOn = false
    /// nil = me.
    @State private var personalDebtMemberId: String?

    /// Sheet escape hatch for "All currencies…" — separate from the
    /// inline `Menu` because the menu's items can't push a sheet directly.
    @State private var showFullCurrencyPicker = false

    private let currencyPrefs = UserCurrencyPreferences.shared

    private var isEditing: Bool { editingTransaction != nil }

    /// Entry currency from a `TransactionFormPrefill` (see there).
    private var prefillCurrency: CurrencyCode?

    /// A new transaction prefilled with `prefill` (quick entry «Подробнее»).
    init(categories: [Category], accounts: [Account], prefill: TransactionFormPrefill, onSave: @escaping () async -> Void) {
        self.init(
            categories: categories,
            accounts: accounts,
            defaultType: prefill.type,
            defaultCategoryId: prefill.categoryId,
            defaultAccountId: prefill.accountId,
            onSave: onSave
        )
        _description = State(initialValue: prefill.description)
        _date = State(initialValue: prefill.date)
        if let amount = prefill.amount, amount > 0 {
            let calculator = CalculatorState()
            calculator.setValue(amount)
            _calculatorState = State(initialValue: calculator)
        }
        prefillCurrency = prefill.currencyCode.flatMap(CurrencyCode.init(code:))
    }

    init(categories: [Category], accounts: [Account], editingTransaction: Transaction? = nil, defaultType: TransactionType? = nil, defaultCategoryId: String? = nil, defaultAccountId: String? = nil, onSave: @escaping () async -> Void) {
        self.categories = categories
        // Money accounts only, whatever the caller passed (contract §A7).
        self.accounts = accounts.moneyAccounts
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

    /// True iff the target account has more than one member (B7). Used to be
    /// "someone else has a transaction on it", so the owner of a freshly
    /// shared account got no «Оплачено с» until the partner wrote a row —
    /// and their expenses went in without an auto-transfer, invisible to the
    /// settlement. The transaction heuristic only bridges the moment before
    /// `AccountSharingIndex` has loaded. False when we have no profile yet.
    private var targetIsShared: Bool {
        guard let acc = selectedAccount, let uid = currentUserId else { return false }
        return AccountSharingIndex.isShared(acc, dataStore: appViewModel.dataStore, currentUserId: uid)
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
        if acc.currency.lowercased() == selectedCurrency.code.lowercased() {
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
        return source.currency.lowercased() != selectedCurrency.code.lowercased()
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

    // MARK: - Personal spending (contract §B2/§B3)

    /// Parties of the target account I may mark: everyone for an owner /
    /// editor, only me otherwise.
    private var personalParties: [PersonalDebtRules.Party] {
        guard let acc = selectedAccount, let me = currentUserId else { return [] }
        let members = appViewModel.dataStore.accountMembership.members(of: acc.id, viewerId: me) ?? []
        let role = PersonalDebtRules.role(of: me, account: acc, members: members)
        return PersonalDebtRules.selectableParties(me: me, myRole: role, account: acc, members: members)
    }

    /// The toggle shows on expenses of a shared account — never on a
    /// transfer leg (the mark lives on the main expense only).
    private var shouldShowPersonalSpending: Bool {
        guard selectedType == .expense, targetIsShared, currentUserId != nil else { return false }
        if let tx = editingTransaction,
           !PersonalDebtRules.isMarkableExpense(type: tx.type, transferGroupId: tx.transferGroupId) {
            return false
        }
        return true
    }

    /// `personal_debt_user_id` to write (nil = not personal).
    private var resolvedPersonalMark: String? {
        guard shouldShowPersonalSpending, let me = currentUserId else { return nil }
        // An untouched existing mark is kept as is, even for a member the
        // membership snapshot doesn't list yet.
        if personalDebtOn, let stored = editingTransaction?.personalDebtUserId,
           personalDebtMemberId?.lowercased() == stored.lowercased() {
            return stored
        }
        return PersonalDebtRules.resolvedMark(
            enabled: personalDebtOn, chosen: personalDebtMemberId, me: me, selectable: personalParties
        )
    }

    // MARK: - View

    /// The edited row is an auto-transfer the OTHER member paid from their
    /// own card: the server rejects any change (42501, only the payer may
    /// write the triplet), so the form explains that and does not offer Save.
    private var isLockedToPayer: Bool {
        guard let tx = editingTransaction else { return false }
        return !appViewModel.dataStore.canModifyAutoTransfer(tx)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLockedToPayer {
                    Section {
                        Label(String(localized: "tx.error.onlyPayerCanEdit"), systemImage: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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
                            // Default to "this account (regular expense)" on
                            // every target switch. Saved defaults still mark
                            // the ⭐ in the picker label so the user can spot
                            // their previous pick, but we never auto-apply
                            // them — too sticky and conflicted with the
                            // settings screen ("removed in Settings, kept
                            // coming back"). Edit mode is handled by
                            // prefillIfEditing — don't clobber it here.
                            if !isEditing {
                                selectedPaymentSourceId = nil
                            }
                            // Auto-sync entry currency to the account's currency
                            // unless the user has manually picked a currency.
                            // Without this, a default selectedCurrency=.rub on a
                            // VND account caused 2M VND → 26277 USD save bugs.
                            if !isEditing {
                                entryCurrency.follow(
                                    accountCurrency: newId.flatMap { id in accounts.first(where: { $0.id == id }) }?.currencyCode
                                )
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

                if shouldShowPersonalSpending, let me = currentUserId {
                    PersonalSpendingSection(
                        isOn: $personalDebtOn,
                        memberId: $personalDebtMemberId,
                        me: me,
                        parties: personalParties,
                        paidFromSharedMoney: resolvedPaymentSource() == nil,
                        nameFor: { appViewModel.dataStore.profilesMap[$0]?.fullName ?? String(localized: "personalDebt.member.unknown") }
                    )
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
                    .disabled(calculatorState.getResult() == nil || isLoading || isLockedToPayer)
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
            .task {
                await appViewModel.dataStore.accountMembership.refresh(viewerId: currentUserId)
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

    /// Tappable chip that opens an inline `Menu` of the user's active
    /// currencies, with an "All currencies…" escape hatch that opens
    /// the full searchable `CurrencyPickerView` as a sheet.
    ///
    /// Uses an accent-tinted border so it reads as an interactive
    /// affordance, not a passive label — the prior inline `Picker`
    /// blended into the secondary row text and got ignored.
    ///
    /// Single-Text-per-row rule applies inside the menu (memory note:
    /// `feedback_swiftui_picker_rows`).
    @ViewBuilder
    private var currencyChip: some View {
        Menu {
            ForEach(currencyPrefs.activeCurrencies) { c in
                Button {
                    currencyPickerSelection.wrappedValue = c
                } label: {
                    // Short row format — long localized names break menu
                    // layout. Full names live in the searchable sheet below.
                    if c == selectedCurrency {
                        Label {
                            Text("\(c.symbol)  \(c.code)")
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text("\(c.symbol)  \(c.code)")
                    }
                }
            }
            Divider()
            Button {
                showFullCurrencyPicker = true
            } label: {
                Label {
                    Text(String(localized: "currencyPicker.allCurrencies"))
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        } label: {
            // Single interpolated Text — keeps the menu trigger label
            // visually stable across iOS builds (the previous two-Text
            // HStack would lose the second Text on certain devices).
            HStack(spacing: 6) {
                Text("\(selectedCurrency.symbol)  \(selectedCurrency.code)")
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
        .accessibilityValue("\(selectedCurrency.symbol) \(selectedCurrency.localizedName)")
        .sheet(isPresented: $showFullCurrencyPicker) {
            // The binding's setter records the user's choice (M4).
            CurrencyPickerView(selection: currencyPickerSelection)
        }
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
        return cm.rates[selectedCurrency.code].map { $0 > 0 } ?? false
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
        if source.currency.lowercased() != selectedCurrency.code.lowercased() {
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
            // Map is kept ONLY for the ⭐ marker in picker labels — never
            // auto-applied as the form's selection. New transactions
            // always start with "this account (regular expense)"; the
            // user picks a personal source explicitly when needed.
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
            // Quick entry named another currency («€20»): keep it, as if
            // picked by hand (it then survives account switches).
            if let prefillCurrency {
                entryCurrency.userSelected(prefillCurrency)
                return
            }
            // New transaction: prefer the currency of the pre-selected account
            // (e.g. when opened from a specific account screen) so the user
            // doesn't accidentally enter a VND amount as RUB on a VND account.
            // Falls back to the user's display preference only when no account
            // is selected yet.
            if let accId = selectedAccountId,
               let acc = accounts.first(where: { $0.id == accId }) {
                entryCurrency.load(acc.currencyCode)
            } else {
                entryCurrency.load(appViewModel.currencyManager.selectedCurrency)
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
           let code = Currency(code: fc.uppercased()),
           let fa = tx.foreignAmount {
            entryCurrency.load(code)
            calculatorState.setValue(fa)
        } else {
            // Account currency — look up from the live accounts list.
            let account = accounts.first(where: { $0.id == tx.accountId })
            let ccyCode = account?.currencyCode ?? appViewModel.currencyManager.dataCurrency
            entryCurrency.load(ccyCode)
            calculatorState.setValue(tx.amountNative.displayAmount)
        }

        description = tx.description ?? ""
        selectedType = tx.type
        selectedCategoryId = tx.categoryId
        selectedAccountId = tx.accountId
        selectedPaymentSourceId = tx.paymentSourceAccountId
        personalDebtOn = tx.personalDebtUserId != nil
        personalDebtMemberId = tx.personalDebtUserId
        // D8: keep the stored time — see `TransactionFormDates`.
        if let txDate = TransactionFormDates.parse(rawDateTime: tx.rawDateTime, fallbackDate: tx.date) {
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
                inputCurrency: selectedCurrency.code,
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

        // M2: an auto-transfer leg is written by the server together with
        // its main expense. Editing it alone re-prices two of the three rows
        // and leaves the expense untouched — the edit goes through the
        // expense. The list routes legs there already; this is the backstop
        // for any other entry point.
        if let tx = editingTransaction, tx.isAutoTransferLeg {
            let name = appViewModel.dataStore.mainExpense(forAutoTransferLeg: tx)?.description
                ?? String(localized: "transaction.transfer")
            errorMessage = String(format: String(localized: "tx.autoTransfer.legReadOnly.body"), name)
            return
        }
        // Server rule: only the payer may write an auto-transfer triplet.
        if isLockedToPayer {
            errorMessage = String(localized: "tx.error.onlyPayerCanEdit")
            return
        }

        let dateStr = TransactionFormDates.string(from: date)

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

        // M10: an edit that leaves amount, currency and account alone keeps
        // the frozen `fx_rate` (fixing a typo in the description of a USD
        // expense must not re-price it at today's rate).
        let unchangedOriginal: Transaction? = {
            guard let tx = editingTransaction,
                  editingBaselineAmount == amountValue,
                  editingBaselineCurrency == selectedCurrency,
                  selectedAccountId == tx.accountId
            else { return nil }
            return tx
        }()

        // M5: conversions frozen into the row use only real, recent quotes
        // (network or server `fx_rates`, < 48 h) — never the hard-coded
        // fallback table an offline start renders with.
        let rates = await cm.ratesForWrite(writeCurrencyCodes(accountCode: accountCode))

        // M3: a cross-currency entry without a rate is refused, never
        // stored 1:1.
        let entry: EntryAmounts
        do {
            entry = try Self.entryAmounts(
                amount: amountValue,
                entryCurrency: selectedCurrency.code,
                accountCurrency: accountCode.code,
                rates: rates,
                unchangedOriginal: unchangedOriginal
            )
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
            return
        }
        let amountInAccountCurrency = entry.native
        let foreignAmount = entry.foreignAmount
        let foreignCurrencyCode = entry.foreignCurrency
        let fxRate = entry.fxRate

        // Legacy `currency` column now always mirrors account.currency on
        // new writes. The foreign-entry currency lives in `foreign_currency`.
        let txCurrencyLabel = accountCode.code

        isLoading = true
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
                    guard selectedType == .expense else { return nil }
                    if shouldShowPaymentSource || selectedAccountId != tx.accountId {
                        return resolvedPaymentSource()
                    }
                    // Picker hidden on an unchanged account (e.g. the
                    // membership changed since): leave the source alone —
                    // a description edit must not dissolve a triplet.
                    return previousSource
                }()
                let sourceChanged = previousSource != resolvedNewSource
                let isMainExpense = tx.type == .expense && tx.transferGroupId == nil
                // M2: `update_expense_with_auto_transfer` never moves rows
                // between accounts, and the plain UPDATE would leave both
                // legs behind. Moving an auto-transfer expense to another
                // account is therefore a re-create, like a source change.
                let movedAutoTransfer = tx.autoTransferGroupId != nil
                    && selectedAccountId != tx.accountId

                // Reassignment path: only fires for the main expense row when
                // the user actually changed the source or moved an
                // auto-transfer expense. Covers:
                //   A. auto-transfer → simple expense (newSource = nil)
                //   B. simple expense → auto-transfer (oldSource = nil)
                //   C. auto-transfer source A → B (both non-nil, differ)
                //   D. auto-transfer moved to another target account
                //   E. unchanged → fall through to the plain update RPC
                // Implementation is client-side delete + recreate; not
                // atomic, but the window is < ~300ms and the failure mode
                // (delete succeeds, create fails) leaves the user without
                // the expense — recoverable by retry. An RPC-level wrapper
                // is tracked for a future migration.
                if isMainExpense && (sourceChanged || movedAutoTransfer) {
                    try await reassignExpenseSource(
                        tx: tx,
                        amountInAccountCurrency: amountInAccountCurrency,
                        foreignAmount: foreignAmount,
                        foreignCurrencyCode: foreignCurrencyCode,
                        fxRate: fxRate,
                        currencyLabel: txCurrencyLabel,
                        userId: userId,
                        dateStr: dateStr,
                        newSource: resolvedNewSource,
                        rates: rates
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
                    // Cross-currency edit: when the existing auto-transfer
                    // group has a transfer-out leg on a source account whose
                    // currency differs from the target, the 9-arg RPC stamps
                    // both legs with `p_amount` (target-currency) — the
                    // 92.5× edit bug. Compute the source-currency amount
                    // up-front and route to the 11-arg overload via
                    // `source_amount` / `source_currency`.
                    var editSourceAmount: Decimal? = nil
                    var editSourceCurrency: String? = nil
                    if useAutoUpdate, let groupId = tx.autoTransferGroupId {
                        // Find the transfer-out leg of this auto-transfer
                        // group (expense type, transfer_group_id set, on a
                        // different account from the main expense).
                        let outLeg = appViewModel.dataStore.transactions.first { other in
                            other.autoTransferGroupId == groupId
                                && other.transferGroupId != nil
                                && other.type == .expense
                                && other.id != tx.id
                        }
                        if let outLeg,
                           let outAccountId = outLeg.accountId,
                           let srcAccount = accounts.first(where: { $0.id == outAccountId }),
                           srcAccount.currency.lowercased() != accountCode.code.lowercased() {
                            let srcCode = srcAccount.currencyCode
                            // M10: unchanged money → the out-leg keeps its
                            // stored amount instead of today's rate.
                            if unchangedOriginal != nil {
                                editSourceAmount = outLeg.amountNative.displayAmount
                            } else {
                                editSourceAmount = try TransactionMath.convertForStorage(
                                    amountInAccountCurrency,
                                    from: accountCode.code,
                                    to: srcCode.code,
                                    rates: rates
                                )
                            }
                            editSourceCurrency = srcCode.code
                        }
                    }
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
                        replaceCurrencyFields: true,
                        source_amount: editSourceAmount,
                        source_currency: editSourceCurrency,
                        personal_debt_user_id: resolvedPersonalMark,
                        // Only a changed mark is sent (contract §B3 PATCH).
                        updatesPersonalDebt: PersonalDebtRules.updatesMark(old: tx.personalDebtUserId, new: resolvedPersonalMark)
                    )
                    try await appViewModel.dataStore.updateTransaction(id: tx.id, input)
                }
            } else {
                // Resolve payment source — only record it when target is shared AND source != target.
                let resolvedPaymentSource = resolvedPaymentSource()
                // Cross-currency: when the source account uses a different
                // currency than the TARGET account, convert the target-currency
                // amount into the source's currency for the transfer-out leg.
                // This is independent of the user's entry currency — ADR-001
                // already normalized to `amountInAccountCurrency` above.
                let source = try sourceLegAmount(
                    sourceId: resolvedPaymentSource,
                    targetCode: accountCode,
                    amountInAccountCurrency: amountInAccountCurrency,
                    rates: rates
                )
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
                    source_amount: source.amount,
                    source_currency: source.currency,
                    personal_debt_user_id: resolvedPersonalMark
                )
                _ = try await appViewModel.dataStore.addTransaction(input)
                // No auto-upsert of payment-source defaults — managed
                // explicitly via Settings → Payment defaults to avoid
                // the "removed it in Settings but it keeps coming back"
                // pattern users complained about.
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }

        isLoading = false
    }

    /// The payment source to record, or nil for a plain expense: only what
    /// the user can see in the «Оплачено с» picker. After moving an expense
    /// to a personal account the stale selection (hidden, not reset in edit
    /// mode) must not resurrect an auto-transfer.
    private func resolvedPaymentSource() -> String? {
        guard shouldShowPaymentSource,
              let sourceId = selectedPaymentSourceId,
              sourceId != selectedAccountId
        else { return nil }
        return sourceId
    }

    /// Transfer-out amount in the SOURCE account's currency when it differs
    /// from the target's (routes the RPC to the cross-currency overload).
    /// Throws `MissingFXRateError` instead of writing a 1:1 leg (M3).
    private func sourceLegAmount(
        sourceId: String?,
        targetCode: CurrencyCode,
        amountInAccountCurrency: Decimal,
        rates: [String: Double]
    ) throws -> (amount: Decimal?, currency: String?) {
        guard let srcId = sourceId,
              let src = accounts.first(where: { $0.id == srcId }),
              src.currency.lowercased() != targetCode.code.lowercased()
        else { return (nil, nil) }
        let srcCode = src.currencyCode
        let amount = try TransactionMath.convertForStorage(
            amountInAccountCurrency,
            from: targetCode.code,
            to: srcCode.code,
            rates: rates
        )
        return (amount, srcCode.code)
    }

    /// Currencies a save may have to convert between: the entry, the
    /// target account and every account an auto-transfer leg may sit on.
    private func writeCurrencyCodes(accountCode: CurrencyCode) -> [String] {
        var codes: Set<String> = [selectedCurrency.code, accountCode.code]
        if let srcId = selectedPaymentSourceId, let src = accounts.first(where: { $0.id == srcId }) {
            codes.insert(src.currencyCode.code)
        }
        if let groupId = editingTransaction?.autoTransferGroupId {
            for leg in appViewModel.dataStore.transactions where leg.autoTransferGroupId == groupId {
                if let accId = leg.accountId, let acc = accounts.first(where: { $0.id == accId }) {
                    codes.insert(acc.currencyCode.code)
                }
            }
        }
        return Array(codes)
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
        newSource: String?,
        rates: [String: Double]
    ) async throws {
        // 0. Everything that can fail without touching the server first: a
        //    missing FX rate for the new source leg must not leave the user
        //    with the old expense deleted and no new one.
        let targetCode: CurrencyCode = selectedAccount?.currencyCode ?? appViewModel.currencyManager.dataCurrency
        let source = try sourceLegAmount(
            sourceId: newSource,
            targetCode: targetCode,
            amountInAccountCurrency: amountInAccountCurrency,
            rates: rates
        )

        // 1. Delete the old row. `DataStore.deleteTransaction` routes
        //    through `delete_expense_with_auto_transfer` when the row has
        //    `auto_transfer_group_id` set, removing all three rows
        //    atomically. For a plain expense it's a single delete.
        //    `deleteTransactionThrowing` throws when the server rejected the
        //    delete, so step 2 never runs on a failure — comparing error
        //    strings used to miss a repeated failure and create a duplicate
        //    expense. A delete queued offline is not a failure.
        let dataStore = appViewModel.dataStore
        try await dataStore.deleteTransactionThrowing(tx)

        // 2. Recreate with the new shape. `addTransaction` will route to
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
            source_amount: source.amount,
            source_currency: source.currency,
            personal_debt_user_id: resolvedPersonalMark
        )
        _ = try await dataStore.addTransaction(input)
        // Saved-default management lives in Settings only — see the
        // matching note in performSave().
    }

    /// What a save writes for the user's entry (ADR-001 decomposition).
    struct EntryAmounts: Equatable, Sendable {
        /// Main units of the ACCOUNT currency → `amount_native`.
        let native: Decimal
        let foreignAmount: Decimal?
        let foreignCurrency: String?
        let fxRate: Decimal?
    }

    /// Pure core of the save path.
    /// - Entry in the account currency → stored verbatim, no `foreign_*`.
    /// - `unchangedOriginal` (the caller saw amount, currency and account
    ///   unchanged) with the same foreign entry → the stored amounts and
    ///   frozen `fx_rate` are kept (M10).
    /// - Otherwise converted at the current rate, rounded for the account
    ///   currency; a missing rate throws `MissingFXRateError` (M3).
    nonisolated static func entryAmounts(
        amount: Decimal,
        entryCurrency: String,
        accountCurrency: String,
        rates: [String: Double],
        unchangedOriginal: Transaction? = nil
    ) throws -> EntryAmounts {
        let entry = entryCurrency.uppercased()
        let account = accountCurrency.uppercased()
        if entry == account {
            return EntryAmounts(native: amount, foreignAmount: nil, foreignCurrency: nil, fxRate: nil)
        }
        if let original = unchangedOriginal,
           original.foreignCurrency?.uppercased() == entry,
           original.foreignAmount == amount {
            let storedNative = original.amountNative.displayAmount
            return EntryAmounts(
                native: storedNative,
                foreignAmount: original.foreignAmount,
                foreignCurrency: entry,
                fxRate: original.fxRate ?? (amount != 0 ? storedNative / amount : nil)
            )
        }
        let native = try TransactionMath.convertForStorage(amount, from: entry, to: account, rates: rates)
        return EntryAmounts(
            native: native,
            foreignAmount: amount,
            foreignCurrency: entry,
            fxRate: amount != 0 ? native / amount : nil
        )
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

    /// DISPLAY-ONLY conversion between two currencies using the USD-based
    /// rate table in `CurrencyManager` (`amount_to = amount_from /
    /// rate[from] * rate[to]`) — the picker hint and the "≈ …" preview.
    /// Returns the input unchanged when a rate is missing, which is fine
    /// for a hint and fatal for a write: the save paths use
    /// `TransactionMath.convertForStorage`, which refuses instead (M3).
    @MainActor
    static func crossConvert(
        amount: Decimal,
        from: CurrencyCode,
        to: CurrencyCode,
        using cm: CurrencyManager
    ) -> Decimal {
        guard from != to else { return amount }
        guard let fromRate = cm.rates[from.code], fromRate > 0,
              let toRate   = cm.rates[to.code],   toRate > 0 else {
            return amount
        }
        return amount / Decimal(fromRate) * Decimal(toRate)
    }
}

/// User-facing text for write errors the server raises on purpose
/// (migrations 20261117120000 / 20261117120200). Anything else falls back to
/// the error's own description.
enum FormErrorMessage {

    static func text(for error: Error) -> String {
        guard let pg = error as? PostgrestError else { return error.localizedDescription }
        // message + hint only: the detail field's name differs between
        // supabase-swift releases (`details` → `detail`), and the server puts
        // the explanation into HINT anyway.
        let context = [pg.message, pg.hint ?? ""].joined(separator: " ")
        switch pg.code {
        case "42501":
            // update_/delete_expense_with_auto_transfer: the triplet has a
            // row on the payer's personal card.
            if context.localizedCaseInsensitiveContains("paid") || context.localizedCaseInsensitiveContains("payer") {
                return String(localized: "tx.error.onlyPayerCanEdit")
            }
            // guard_account_owner_currency: currency is the owner's call.
            if context.localizedCaseInsensitiveContains("currency") {
                return String(localized: "account.currency.ownerOnly.hint")
            }
            return String(localized: "tx.error.noPermission")
        case "P0002":
            // update_expense_with_auto_transfer: the main row is gone
            // (deleted on the partner's phone meanwhile).
            return String(localized: "tx.error.alreadyDeleted")
        case "PGRST202", "PGRST205", "42883", "42P01":
            // The server doesn't have this function / table yet (a feature
            // whose migration isn't applied) — never show the raw
            // «Could not find the function … in the schema cache».
            return String(localized: "server.error.featureNotReady")
        case "23514" where context.localizedCaseInsensitiveContains("currency"):
            // guard_account_owner_currency: the account already has rows.
            return String(localized: "account.currency.locked.hint")
        default:
            return error.localizedDescription
        }
    }
}

/// Wall-clock timestamps for the transaction / transfer forms (D8).
///
/// The forms write `transactions.date` as local wall-clock digits without an
/// offset ("2026-11-17T00:30:00"). The column is `timestamptz` and PostgREST
/// runs in UTC, so the digits are stored verbatim and come back as
/// "2026-11-17T00:30:00+00:00" (prod: `date − created_at` is +7 h for the
/// UTC+7 user's iOS rows). `tx.date` = the first 10 characters is therefore
/// the user's local day, and the whole app relies on that.
///
/// Reading back must use the SAME convention: take the first 19 characters
/// and interpret them in the writer's time zone. The old parser required the
/// exact "yyyy-MM-dd'T'HH:mm:ss" string, so every server row ("+00:00"
/// suffix) failed to parse, the form fell back to midnight, and any edit —
/// even of the description — rewrote the time as 00:00. Parsing the digits
/// as real UTC would be just as wrong: each edit would shift the time by the
/// user's offset.
enum TransactionFormDates {

    static func formatter(timeZone: TimeZone) -> DateFormatter {
        AppDateFormatters.posix("yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone)
    }

    /// `date` as the wall-clock string the forms write.
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    /// Inverse of `string(from:)` for anything the DB or the offline queue
    /// hands back: "2026-11-17T00:30:00+00:00", "…T00:30:00.123+00:00",
    /// "2026-11-17 00:30:00+00", the bare "2026-11-17T00:30:00", or a
    /// date-only "2026-11-17" (→ local midnight).
    static func parse(rawDateTime: String, fallbackDate: String, timeZone: TimeZone = .current) -> Date? {
        let full = formatter(timeZone: timeZone)
        if rawDateTime.count >= 19 {
            let digits = String(rawDateTime.prefix(19)).replacingOccurrences(of: " ", with: "T")
            if let date = full.date(from: digits) { return date }
        }
        let day = formatter(timeZone: timeZone)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(rawDateTime.prefix(10))) ?? day.date(from: String(fallbackDate.prefix(10)))
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
