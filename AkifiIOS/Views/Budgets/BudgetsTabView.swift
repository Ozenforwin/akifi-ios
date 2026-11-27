import SwiftUI

/// The «Бюджеты» tab: two sections behind a segmented control right under
/// the title — «Бюджеты | Подписки» (Vladimir, 2026-11-28). The toolbar «+»
/// adds whatever is shown.
struct BudgetsTabView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case budgets, subscriptions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .budgets: String(localized: "budget.title")
            case .subscriptions: String(localized: "subscriptions.title")
            }
        }
    }

    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = BudgetsViewModel()
    @State private var segment: Segment = .budgets
    @State private var showSubscriptionForm = false
    @State private var editingSubscription: SubscriptionTracker?
    @State private var subscriptionsVM = SubscriptionsViewModel()
    @State private var sharingBudget: Budget?
    @State private var historyBudget: BudgetHistoryTarget?
    @ScaledMetric(relativeTo: .body) private var subscriptionIconSize: CGFloat = 40

    /// Metrics travel with the budget so the sheet's header matches the
    /// card that was tapped without recomputing them.
    struct BudgetHistoryTarget: Identifiable {
        let budget: Budget
        let resolved: ResolvedBudgetMetrics
        var id: String { budget.id }
    }

    private var dataStore: DataStore { appViewModel.dataStore }
    private var isNewUser: Bool { dataStore.transactions.isEmpty }

    /// Monthly-equivalent commitment of the active subscriptions, in base
    /// currency kopecks (the display currency conversion happens in
    /// `formatAmount`). Mixed-currency lists must be FX-normalized before
    /// summing — see `BudgetMath.activeSubscriptionsMonthlyTotalInBase`.
    private var activeSubscriptionsMonthlyTotal: Int64 {
        BudgetMath.activeSubscriptionsMonthlyTotalInBase(
            subscriptions: isNewUser ? DemoData.subscriptions : dataStore.subscriptions,
            currencyContext: dataStore.currencyContext
        )
    }

    var body: some View {
        // Server numbers when available (identical for every member of a
        // shared budget), local BudgetMath otherwise — memoized in
        // BudgetMetricsStore, shared with the widget and «Доступно сегодня».
        let budgetsWithMetrics = viewModel.sortedBudgets(dataStore: dataStore)

        return NavigationStack {
            List {
                // «Бюджеты | Подписки» right under the large title (a pinned
                // bar blurred the title with its scroll-edge effect).
                Picker(String(localized: "budget.title"), selection: $segment.animation(.snappy)) {
                    ForEach(Segment.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .spotlight(.subscriptions)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))

                // MARK: - Budgets
                if segment == .budgets {
                if isNewUser {
                    // Demo budget with blur
                    Section {
                        let metrics = BudgetMath.compute(budget: DemoData.budget, transactions: DemoData.transactions, subscriptions: DemoData.subscriptions, categories: DemoData.categories, currencyContext: dataStore.currencyContext)
                        BudgetCardView(budget: DemoData.budget, metrics: metrics, categories: DemoData.categories)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .demoBlur(
                                hint: String(localized: "welcome.budgetHint"),
                                buttonTitle: String(localized: "common.create")
                            ) { viewModel.showForm = true }
                    }
                } else if dataStore.isLoading && dataStore.budgets.isEmpty {
                    Section { LoadingView() }
                        .listRowSeparator(.hidden)
                } else if !dataStore.budgets.isEmpty {
                    // Health summary
                    if budgetsWithMetrics.count > 1 {
                        Section {
                            BudgetHealthSummaryView(
                                budgets: budgetsWithMetrics.map(\.budget),
                                allMetrics: budgetsWithMetrics.map(\.resolved.metrics)
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(Array(budgetsWithMetrics.enumerated()), id: \.element.budget.id) { index, item in
                            let budget = item.budget
                            let resolved = item.resolved
                            BudgetCardView(
                                budget: budget,
                                metrics: resolved.metrics,
                                categories: dataStore.categories,
                                serverCategories: resolved.server?.categories ?? [],
                                isPartial: resolved.isPartial
                            )
                                .spotlight(index == 0 ? .budgetCard : nil)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .contentShape(Rectangle())
                                // The long-press preview lifts the card itself.
                                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: CardStyle.Size.regular.cornerRadius, style: .continuous))
                                .onTapGesture {
                                    historyBudget = BudgetHistoryTarget(budget: budget, resolved: resolved)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await viewModel.deleteBudget(budget)
                                            await dataStore.loadAll()
                                        }
                                    } label: {
                                        Label(String(localized: "budget.archive"), systemImage: "archivebox.fill")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        viewModel.editingBudget = budget
                                    } label: {
                                        Label(String(localized: "common.edit"), systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .contextMenu {
                                    Button {
                                        viewModel.editingBudget = budget
                                    } label: {
                                        Label(String(localized: "common.edit"), systemImage: "pencil")
                                    }
                                    Button {
                                        sharingBudget = budget
                                    } label: {
                                        Label(String(localized: "common.share"), systemImage: "person.badge.plus")
                                    }
                                }
                        }
                    }
                } else {
                    Section {
                        EmptyStateView(
                            title: String(localized: "budget.noBudgets"),
                            systemImage: "wallet.bifold.fill",
                            description: String(localized: "budget.noBudgets.description"),
                            actionTitle: String(localized: "common.create")
                        ) { viewModel.showForm = true }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                }

                // MARK: - Subscriptions
                if segment == .subscriptions {
                Section {
                    if activeSubscriptionsMonthlyTotal > 0 {
                        Text(String(localized: "subscriptions.monthlyTotal.\(appViewModel.currencyManager.formatAmount(activeSubscriptionsMonthlyTotal.displayAmount, wholeUnits: true))"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    if isNewUser {
                        // Demo subscriptions with single blur overlay
                        VStack(spacing: 8) {
                            ForEach(DemoData.subscriptions) { sub in
                                subscriptionRow(sub)
                            }
                        }
                        .demoBlur(
                            hint: String(localized: "welcome.subscriptionHint"),
                            buttonTitle: String(localized: "subscriptions.add")
                        ) { showSubscriptionForm = true }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                    } else if dataStore.subscriptions.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "repeat.circle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(String(localized: "subscriptions.noActive"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 24)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(subscriptionsByStatus, id: \.status) { group in
                            if !group.items.isEmpty {
                                Text(group.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                                    .accessibilityAddTraits(.isHeader)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                                ForEach(group.items) { sub in
                                    subscriptionRow(sub)
                                        .opacity(sub.status == .cancelled ? 0.55 : 1.0)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowBackground(Color.clear)
                                        .contentShape(Rectangle())
                                        .onTapGesture { editingSubscription = sub }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                Task {
                                                    try? await SubscriptionTrackerRepository().delete(id: sub.id)
                                                    await dataStore.loadAll()
                                                }
                                            } label: {
                                                Label(String(localized: "common.delete"), systemImage: "trash.fill")
                                            }
                                        }
                                        .swipeActions(edge: .leading) {
                                            Button {
                                                editingSubscription = sub
                                            } label: {
                                                Label(String(localized: "common.edit"), systemImage: "pencil")
                                            }
                                            .tint(.blue)
                                        }
                                }
                            }
                        }
                    }
                }
                }

            }
            .listStyle(.plain)
            // Rows are cards and caption-sized group titles — let each be
            // as tall as its content (the 44 pt default padded the titles).
            .environment(\.defaultMinListRowHeight, 0)
            // Cards on the grouped background, like Home and Analytics.
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            // The system insets content for the tab bar; this is only the
            // room the floating «+» needs so the last row can scroll clear.
            .contentMargins(.bottom, AkifiChrome.floatingButtonClearance, for: .scrollContent)
            .refreshable {
                await dataStore.loadAll()
                // An explicit pull always asks the server (Y2): a partner's
                // spending may have changed nothing this phone can see.
                await viewModel.loadMetrics(dataStore: dataStore, force: true)
            }
            // No-op when nothing changed since the last fetch; data changes
            // also refresh via SharedSnapshotWriter after every DataStore load.
            .task { await viewModel.loadMetrics(dataStore: dataStore) }
            .navigationTitle(String(localized: "budget.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Adds what the segmented control shows.
                    Button {
                        switch segment {
                        case .budgets: viewModel.showForm = true
                        case .subscriptions: showSubscriptionForm = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(segment == .budgets ? String(localized: "budget.newBudget") : String(localized: "subscriptions.add"))
                }
            }
            .sheet(isPresented: $viewModel.showForm) {
                BudgetFormView(
                    categories: dataStore.displayCategories,
                    accounts: dataStore.accounts
                ) {
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $viewModel.editingBudget) { budget in
                BudgetFormView(
                    categories: dataStore.displayCategories,
                    accounts: dataStore.accounts,
                    editingBudget: budget
                ) {
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $historyBudget) { target in
                BudgetTransactionsSheet(budget: target.budget, resolved: target.resolved)
            }
            .sheet(isPresented: $showSubscriptionForm) {
                SubscriptionFormView { name, amount, period, color, currency, reminderDays, lastDate, nextDate, categoryId, accountId in
                    let created = await subscriptionsVM.create(
                        name: name, amount: amount, period: period, color: color,
                        currency: currency, reminderDays: reminderDays,
                        lastPaymentDate: lastDate, nextPaymentDate: nextDate,
                        categoryId: categoryId,
                        accountId: accountId
                    )
                    guard created else {
                        return subscriptionsVM.error ?? String(localized: "common.error")
                    }
                    await dataStore.loadAll()
                    return nil
                }
            }
            .sheet(item: $editingSubscription) { sub in
                EditSubscriptionFormView(subscription: sub) {
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $sharingBudget) { budget in
                ShareBudgetView(budget: budget)
            }
        }
    }

    // MARK: - Subscription grouping by status

    private struct SubscriptionGroup {
        let status: SubscriptionTrackerStatus
        let title: String
        let items: [SubscriptionTracker]
    }

    private var subscriptionsByStatus: [SubscriptionGroup] {
        let active = dataStore.subscriptions.filter { $0.status == .active }
        let paused = dataStore.subscriptions.filter { $0.status == .paused }
        let archive = dataStore.subscriptions.filter { $0.status == .cancelled }
        return [
            SubscriptionGroup(status: .active, title: String(localized: "subscriptions.section.active"), items: active),
            SubscriptionGroup(status: .paused, title: String(localized: "subscriptions.section.paused"), items: paused),
            SubscriptionGroup(status: .cancelled, title: String(localized: "subscriptions.section.archive"), items: archive)
        ]
    }

    // MARK: - Subscription row

    private func subscriptionRow(_ sub: SubscriptionTracker) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: sub.iconColor ?? "#60A5FA"))
                    .frame(width: subscriptionIconSize, height: subscriptionIconSize)
                    .overlay {
                        Text(String(sub.serviceName.prefix(1)).uppercased())
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sub.serviceName)
                            .font(.subheadline.weight(.medium))
                        if sub.status != .active {
                            Image(systemName: sub.status.systemImage)
                                .font(.caption2)
                                .foregroundStyle(sub.status == .paused ? Color.warning : .secondary)
                        }
                    }
                    Text(periodLabel(sub.billingPeriod))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatSubscriptionAmount(sub))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    let days = sub.daysRemaining
                    Text(subscriptionDueLabel(sub))
                        .font(.caption)
                        .foregroundStyle(days <= 3 ? Color.expense : .secondary)
                }
            }

            // Billing-cycle progress: the system bar, solid colour (was a
            // hand-made gradient bar).
            ProgressView(value: min(max(sub.cycleProgress, 0), 1))
                .tint(progressColor(daysRemaining: sub.daysRemaining))
                .accessibilityHidden(true)
        }
        .akifiCard(.compact)
        .accessibilityElement(children: .combine)
    }

    private func progressColor(daysRemaining: Int) -> Color {
        if daysRemaining <= 2 { return Color.expense }
        if daysRemaining <= 7 { return Color.warning }
        return Color.accent
    }

    // One formatter per precision, not one per subscription row per render (P5).
    private static let wholeAmountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.minimumFractionDigits = 0
        return f
    }()

    private static let centsAmountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    private func formatSubscriptionAmount(_ sub: SubscriptionTracker) -> String {
        let amount = sub.amount.displayAmount
        let cur = sub.currency?.uppercased() ?? "RUB"
        let symbol: String = switch cur {
        case "USD": "$"; case "EUR": "€"; case "RUB": "₽"
        case "VND": "₫"; case "THB": "฿"; case "IDR": "Rp"
        default: cur
        }
        let whole = cur == "RUB" || cur == "VND" || cur == "THB" || cur == "IDR"
        let formatter = whole ? Self.wholeAmountFormatter : Self.centsAmountFormatter
        let formatted = formatter.string(from: amount as NSDecimalNumber) ?? "0"
        return "\(formatted) \(symbol)"
    }

    private func subscriptionDueLabel(_ sub: SubscriptionTracker) -> String {
        if sub.isOverdue {
            return String(localized: "subscriptions.overdue.\(sub.daysOverdue)")
        }
        let days = sub.daysRemaining
        return days == 0
            ? String(localized: "subscriptions.today")
            : String(localized: "subscriptions.inDays.\(days)")
    }

    private func periodLabel(_ period: BillingPeriod) -> String {
        switch period {
        case .weekly: String(localized: "period.weekly")
        case .monthly: String(localized: "period.monthly")
        case .quarterly: String(localized: "period.quarterly")
        case .yearly: String(localized: "period.yearly")
        case .custom: String(localized: "period.custom")
        }
    }
}

// MARK: - Edit Subscription Form

struct EditSubscriptionFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionTracker
    let onSave: () async -> Void

    @State private var viewModel = SubscriptionsViewModel()

    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var selectedColor: String = "#60A5FA"
    @State private var reminderDays: Int = 1
    @State private var selectedCategoryId: String?
    @State private var selectedAccountId: String?
    @State private var isSaving = false
    @State private var status: SubscriptionTrackerStatus = .active
    @State private var errorMessage: String?

    private var expenseCategories: [Category] {
        appViewModel.dataStore.displayCategories.filter { $0.type == .expense }
    }

    private var accounts: [Account] {
        appViewModel.dataStore.accounts
    }

    @State private var specifyLastPayment = false
    @State private var lastPaymentDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var nextPaymentDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var nextManuallyEdited = false

    @State private var showHistory = false

    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "subscriptions.subscription")) {
                    TextField(String(localized: "common.name"), text: $name)
                    TextField(String(localized: "common.amount"), text: $amountText)
                        .keyboardType(.decimalPad)
                    // User-action bindings, NOT .onChange — onChange also
                    // fires on prefill()'s programmatic assignments, which
                    // latched nextManuallyEdited and froze auto-recalc (bug:
                    // setting the last-payment date never moved the next one).
                    Picker(String(localized: "common.period"), selection: Binding(
                        get: { period },
                        set: { period = $0; recalcNextIfAuto() }
                    )) {
                        Text(String(localized: "billingPeriod.weekly")).tag(BillingPeriod.weekly)
                        Text(String(localized: "billingPeriod.monthly")).tag(BillingPeriod.monthly)
                        Text(String(localized: "billingPeriod.quarterly")).tag(BillingPeriod.quarterly)
                        Text(String(localized: "billingPeriod.yearly")).tag(BillingPeriod.yearly)
                    }
                    HStack {
                        Text(String(localized: "common.currency"))
                            .foregroundStyle(.primary)
                        Spacer()
                        ActiveCurrencyPicker(selection: $selectedCurrency)
                    }
                    .frame(minHeight: 44)

                    Picker(String(localized: "subscriptions.category"), selection: $selectedCategoryId) {
                        Text(String(localized: "subscriptions.noCategory")).tag(String?.none)
                        ForEach(expenseCategories, id: \.id) { cat in
                            Text("\(cat.icon) \(cat.name)").tag(String?(cat.id))
                        }
                    }

                    Picker(String(localized: "subscription.account"), selection: $selectedAccountId) {
                        Text(String(localized: "subscription.account.none")).tag(String?.none)
                        ForEach(accounts, id: \.id) { account in
                            Text("\(account.icon) \(account.name)").tag(String?(account.id))
                        }
                    }
                }

                Section {
                    Picker(String(localized: "subscriptions.status"), selection: $status) {
                        Text(String(localized: "subscriptions.status.active")).tag(SubscriptionTrackerStatus.active)
                        Text(String(localized: "subscriptions.status.paused")).tag(SubscriptionTrackerStatus.paused)
                        Text(String(localized: "subscriptions.status.cancelled")).tag(SubscriptionTrackerStatus.cancelled)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(statusFooter(status))
                }

                Section {
                    Toggle(String(localized: "subscriptions.specifyLastPayment"), isOn: Binding(
                        get: { specifyLastPayment },
                        set: { specifyLastPayment = $0; recalcNextIfAuto() }
                    ))
                    if specifyLastPayment {
                        DatePicker(
                            String(localized: "subscriptions.lastPayment"),
                            selection: Binding(
                                get: { lastPaymentDate },
                                set: { lastPaymentDate = $0; recalcNextIfAuto() }
                            ),
                            displayedComponents: .date
                        )
                    }
                    DatePicker(
                        String(localized: "subscriptions.nextPayment"),
                        selection: Binding(
                            get: { nextPaymentDate },
                            set: { nextPaymentDate = $0; nextManuallyEdited = true }
                        ),
                        displayedComponents: .date
                    )
                } header: {
                    Text(String(localized: "subscriptions.datesSection"))
                } footer: {
                    Text(String(localized: "subscriptions.autoCalculated"))
                }

                Section {
                    Button {
                        showHistory = true
                    } label: {
                        HStack {
                            Label(String(localized: "subscriptions.paymentHistory"), systemImage: "list.bullet.rectangle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }

                Section(String(localized: "subscriptions.reminder")) {
                    Picker(String(localized: "subscriptions.remind"), selection: $reminderDays) {
                        Text(String(localized: "subscriptions.onChargeDay")).tag(0)
                        Text(String(localized: "subscriptions.daysBefore.1")).tag(1)
                        Text(String(localized: "subscriptions.daysBefore.2")).tag(2)
                        Text(String(localized: "subscriptions.daysBefore.3")).tag(3)
                        Text(String(localized: "subscriptions.daysBefore.5")).tag(5)
                        Text(String(localized: "subscriptions.daysBefore.7")).tag(7)
                        Text(String(localized: "subscriptions.daysBefore.14")).tag(14)
                        Text(String(localized: "subscriptions.daysBefore.30")).tag(30)
                    }
                }

                Section(String(localized: "common.color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
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
            }
            .navigationTitle(String(localized: "common.editTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save")) {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || amountText.isEmpty || isSaving)
                }
            }
            .onAppear(perform: prefill)
            .sheet(isPresented: $showHistory) {
                SubscriptionPaymentsHistoryView(subscription: subscription) {
                    await onSave()
                }
            }
            .alert(
                String(localized: "common.error"),
                isPresented: .init(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(String(localized: "common.ok")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Recomputes the next payment date from the last-payment anchor (or
    /// today) unless the user explicitly overrode it via the next picker.
    private func recalcNextIfAuto() {
        guard !nextManuallyEdited else { return }
        let base = specifyLastPayment ? lastPaymentDate : Calendar.current.startOfDay(for: Date())
        nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(from: base, period: period)
    }

    private func statusFooter(_ status: SubscriptionTrackerStatus) -> String {
        switch status {
        case .active: return String(localized: "subscriptions.status.footer.active")
        case .paused: return String(localized: "subscriptions.status.footer.paused")
        case .cancelled: return String(localized: "subscriptions.status.footer.cancelled")
        }
    }

    private func prefill() {
        name = subscription.serviceName
        amountText = "\(subscription.amount.displayAmount)"
        period = subscription.billingPeriod
        selectedColor = subscription.iconColor ?? "#60A5FA"
        reminderDays = subscription.reminderDays
        selectedCategoryId = subscription.categoryId
        selectedAccountId = subscription.accountId
        status = subscription.status
        if let cur = subscription.currency, let code = Currency(code: cur.uppercased()) {
            selectedCurrency = code
        }
        if let lastStr = subscription.lastPaymentDate,
           let lastDate = SubscriptionDateEngine.parseDbDate(lastStr) {
            specifyLastPayment = true
            lastPaymentDate = lastDate
        }
        if let nextStr = subscription.nextPaymentDate,
           let nextDate = SubscriptionDateEngine.parseDbDate(nextStr) {
            nextPaymentDate = nextDate
        } else {
            nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(
                from: lastPaymentDate, period: period
            )
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard let decimal = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        // Seed VM with our current subscription so update can reschedule notifications.
        viewModel.subscriptions = [subscription]
        let updated = await viewModel.update(
            id: subscription.id,
            name: name,
            amount: amountCents,
            period: period,
            color: selectedColor,
            currency: selectedCurrency.code,
            reminderDays: reminderDays,
            lastPaymentDate: specifyLastPayment ? lastPaymentDate : nil,
            nextPaymentDate: nextPaymentDate,
            status: status,
            categoryId: selectedCategoryId,
            accountId: selectedAccountId
        )
        guard updated else {
            errorMessage = viewModel.error ?? String(localized: "common.error")
            return
        }
        if status != subscription.status {
            AnalyticsService.logSubscriptionStatusChange(to: status.rawValue)
        }
        await onSave()
        dismiss()
    }
}
