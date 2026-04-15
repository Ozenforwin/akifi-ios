import SwiftUI

struct BudgetsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = BudgetsViewModel()
    @State private var showSubscriptionForm = false
    @State private var editingSubscription: SubscriptionTracker?
    @State private var subscriptionsVM = SubscriptionsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var isNewUser: Bool { dataStore.transactions.isEmpty }

    /// Budgets sorted by criticality: overLimit first, then nearLimit, warning, onTrack
    private var sortedBudgetsWithMetrics: [(budget: Budget, metrics: BudgetMetrics)] {
        let items = dataStore.budgets.map { budget in
            (budget: budget, metrics: BudgetMath.compute(budget: budget, transactions: dataStore.transactions))
        }
        return items.sorted { a, b in
            let priority: (BudgetStatus) -> Int = {
                switch $0 {
                case .overLimit: return 0
                case .nearLimit: return 1
                case .warning: return 2
                case .onTrack: return 3
                }
            }
            let pa = priority(a.metrics.status)
            let pb = priority(b.metrics.status)
            if pa != pb { return pa < pb }
            return a.metrics.utilization > b.metrics.utilization
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Budgets
                if isNewUser {
                    // Demo budget with blur
                    Section {
                        let metrics = BudgetMath.compute(budget: DemoData.budget, transactions: DemoData.transactions)
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
                    if sortedBudgetsWithMetrics.count > 1 {
                        Section {
                            BudgetHealthSummaryView(
                                budgets: sortedBudgetsWithMetrics.map(\.budget),
                                allMetrics: sortedBudgetsWithMetrics.map(\.metrics)
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(Array(sortedBudgetsWithMetrics.enumerated()), id: \.element.budget.id) { index, item in
                            let budget = item.budget
                            let metrics = item.metrics
                            BudgetCardView(budget: budget, metrics: metrics, categories: dataStore.categories)
                                .spotlight(index == 0 ? .budgetCard : nil)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
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

                // MARK: - Subscriptions
                Section {
                    HStack {
                        Text(String(localized: "subscriptions.title"))
                            .font(.headline)
                        Spacer()
                        Button {
                            showSubscriptionForm = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accent)
                        }
                    }
                    .spotlight(.subscriptions)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

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
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
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

                // Bottom spacer
                Color.clear.frame(height: 120)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle(String(localized: "budget.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.showForm = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showForm) {
                BudgetFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts
                ) {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $viewModel.editingBudget) { budget in
                BudgetFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts,
                    editingBudget: budget
                ) {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showSubscriptionForm) {
                SubscriptionFormView { name, amount, period, color, currency, reminderDays, lastDate, nextDate in
                    await subscriptionsVM.create(
                        name: name, amount: amount, period: period, color: color,
                        currency: currency, reminderDays: reminderDays,
                        lastPaymentDate: lastDate, nextPaymentDate: nextDate
                    )
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $editingSubscription) { sub in
                EditSubscriptionFormView(subscription: sub) {
                    await dataStore.loadAll()
                }
                .presentationBackground(.ultraThinMaterial)
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
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: sub.iconColor ?? "#60A5FA"))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text(String(sub.serviceName.prefix(1)).uppercased())
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    }

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
                    let days = sub.daysRemaining
                    Text(days == 0 ? String(localized: "subscriptions.today") : String(localized: "subscriptions.inDays.\(days)"))
                        .font(.caption2)
                        .foregroundStyle(days <= 3 ? Color.expense : .secondary)
                }
            }

            // Progress bar
            GeometryReader { geo in
                let progress = sub.cycleProgress
                let color = progressColor(daysRemaining: sub.daysRemaining)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.systemGray5))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.gradient)
                        .frame(width: geo.size.width * min(progress, 1.0))
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    private func progressColor(daysRemaining: Int) -> Color {
        if daysRemaining <= 2 { return Color.expense }
        if daysRemaining <= 7 { return Color.warning }
        return Color.accent
    }

    private func formatSubscriptionAmount(_ sub: SubscriptionTracker) -> String {
        let amount = sub.amount.displayAmount
        let cur = sub.currency?.uppercased() ?? "RUB"
        let symbol: String = switch cur {
        case "USD": "$"; case "EUR": "€"; case "RUB": "₽"
        case "VND": "₫"; case "THB": "฿"; case "IDR": "Rp"
        default: cur
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = (cur == "RUB" || cur == "VND" || cur == "THB" || cur == "IDR") ? 0 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        let formatted = formatter.string(from: amount as NSDecimalNumber) ?? "0"
        return "\(formatted) \(symbol)"
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
    @State private var isSaving = false
    @State private var status: SubscriptionTrackerStatus = .active

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
                    Picker(String(localized: "common.period"), selection: $period) {
                        Text(String(localized: "billingPeriod.weekly")).tag(BillingPeriod.weekly)
                        Text(String(localized: "billingPeriod.monthly")).tag(BillingPeriod.monthly)
                        Text(String(localized: "billingPeriod.quarterly")).tag(BillingPeriod.quarterly)
                        Text(String(localized: "billingPeriod.yearly")).tag(BillingPeriod.yearly)
                    }
                    .onChange(of: period) { _, newValue in
                        if !nextManuallyEdited {
                            let base = specifyLastPayment ? lastPaymentDate : Calendar.current.startOfDay(for: Date())
                            nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(from: base, period: newValue)
                        }
                    }
                    Picker(String(localized: "common.currency"), selection: $selectedCurrency) {
                        ForEach(CurrencyCode.allCases, id: \.self) { currency in
                            Text("\(currency.symbol) \(currency.name)").tag(currency)
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
                    Toggle(String(localized: "subscriptions.specifyLastPayment"), isOn: $specifyLastPayment)
                    if specifyLastPayment {
                        DatePicker(
                            String(localized: "subscriptions.lastPayment"),
                            selection: $lastPaymentDate,
                            displayedComponents: .date
                        )
                        .onChange(of: lastPaymentDate) { _, newValue in
                            if !nextManuallyEdited {
                                nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(from: newValue, period: period)
                            }
                        }
                    }
                    DatePicker(
                        String(localized: "subscriptions.nextPayment"),
                        selection: $nextPaymentDate,
                        displayedComponents: .date
                    )
                    .onChange(of: nextPaymentDate) { _, _ in
                        nextManuallyEdited = true
                    }
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
                .presentationBackground(.ultraThinMaterial)
            }
        }
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
        status = subscription.status
        if let cur = subscription.currency, let code = CurrencyCode(rawValue: cur.uppercased()) {
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
        guard let decimal = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        // Seed VM with our current subscription so update can reschedule notifications.
        viewModel.subscriptions = [subscription]
        await viewModel.update(
            id: subscription.id,
            name: name,
            amount: amountCents,
            period: period,
            color: selectedColor,
            currency: selectedCurrency.rawValue,
            reminderDays: reminderDays,
            lastPaymentDate: specifyLastPayment ? lastPaymentDate : nil,
            nextPaymentDate: nextPaymentDate,
            status: status
        )
        if status != subscription.status {
            AnalyticsService.logSubscriptionStatusChange(to: status.rawValue)
        }
        await onSave()
        dismiss()
    }
}
