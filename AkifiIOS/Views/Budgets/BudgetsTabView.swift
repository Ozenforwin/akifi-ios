import SwiftUI

struct BudgetsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = BudgetsViewModel()
    @State private var showSubscriptionForm = false
    @State private var editingSubscription: SubscriptionTracker?
    @State private var subscriptionsVM = SubscriptionsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var isNewUser: Bool { dataStore.transactions.isEmpty }

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
                    Section {
                        ForEach(Array(dataStore.budgets.enumerated()), id: \.element.id) { index, budget in
                            let metrics = BudgetMath.compute(budget: budget, transactions: dataStore.transactions)
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
                        ForEach(dataStore.subscriptions) { sub in
                            subscriptionRow(sub)
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
                SubscriptionFormView { name, amount, period, color in
                    await subscriptionsVM.create(name: name, amount: amount, period: period, color: color)
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
                    Text(sub.serviceName)
                        .font(.subheadline.weight(.medium))
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

    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var selectedColor: String = "#60A5FA"
    @State private var reminderDays: Int = 1
    @State private var isSaving = false

    private static let reminderOptions = [0, 1, 2, 3, 5, 7, 14, 30]
    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]
    private let repo = SubscriptionTrackerRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "subscriptions.subscription")) {
                    TextField(String(localized: "common.name"), text: $name)
                    TextField(String(localized: "common.amount"), text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker(String(localized: "common.period"), selection: $period) {
                        Text(String(localized: "period.monthShort")).tag(BillingPeriod.monthly)
                        Text(String(localized: "period.quarterShort")).tag(BillingPeriod.quarterly)
                        Text(String(localized: "period.yearShort")).tag(BillingPeriod.yearly)
                    }
                    Picker(String(localized: "common.currency"), selection: $selectedCurrency) {
                        ForEach(CurrencyCode.allCases, id: \.self) { currency in
                            Text("\(currency.symbol) \(currency.name)").tag(currency)
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
            .onAppear {
                name = subscription.serviceName
                amountText = "\(subscription.amount.displayAmount)"
                period = subscription.billingPeriod
                selectedColor = subscription.iconColor ?? "#60A5FA"
                reminderDays = subscription.reminderDays
                if let cur = subscription.currency, let code = CurrencyCode(rawValue: cur.uppercased()) {
                    selectedCurrency = code
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        guard let decimal = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return }
        let input = UpdateSubscriptionInput(
            service_name: name,
            amount: decimal,
            billing_period: period.rawValue,
            icon_color: selectedColor,
            reminder_days: reminderDays,
            currency: selectedCurrency.rawValue
        )
        try? await repo.update(id: subscription.id, input)
        await onSave()
        dismiss()
    }
}
