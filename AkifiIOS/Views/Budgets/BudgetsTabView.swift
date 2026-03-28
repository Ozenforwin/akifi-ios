import SwiftUI

struct BudgetsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = BudgetsViewModel()
    @State private var showSubscriptionForm = false
    @State private var editingSubscription: SubscriptionTracker?
    @State private var subscriptionsVM = SubscriptionsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Budgets
                if dataStore.isLoading && dataStore.budgets.isEmpty {
                    Section { LoadingView() }
                        .listRowSeparator(.hidden)
                } else if !dataStore.budgets.isEmpty {
                    Section {
                        ForEach(dataStore.budgets) { budget in
                            let metrics = BudgetMath.compute(budget: budget, transactions: dataStore.transactions)
                            BudgetCardView(budget: budget, metrics: metrics, categories: dataStore.categories)
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
                                        Label("Архивировать", systemImage: "archivebox.fill")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        viewModel.editingBudget = budget
                                    } label: {
                                        Label("Изменить", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                } else {
                    Section {
                        EmptyStateView(
                            title: "Нет бюджетов",
                            systemImage: "wallet.bifold.fill",
                            description: "Создайте бюджет, чтобы контролировать расходы",
                            actionTitle: "Создать"
                        ) { viewModel.showForm = true }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                // MARK: - Subscriptions
                Section {
                    HStack {
                        Text("Подписки")
                            .font(.headline)
                        Spacer()
                        Button {
                            showSubscriptionForm = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accent)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    if dataStore.subscriptions.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "repeat.circle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Нет активных подписок")
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
                                        Label("Удалить", systemImage: "trash.fill")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        editingSubscription = sub
                                    } label: {
                                        Label("Изменить", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }

                // Bottom spacer
                Color.clear.frame(height: 80)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .refreshable {
                await dataStore.loadAll()
            }
            .navigationTitle("Бюджеты")
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
            }
            .sheet(item: $viewModel.editingBudget) { budget in
                BudgetFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts,
                    editingBudget: budget
                ) {
                    await dataStore.loadAll()
                }
            }
            .sheet(isPresented: $showSubscriptionForm) {
                SubscriptionFormView { name, amount, period, color in
                    await subscriptionsVM.create(name: name, amount: amount, period: period, color: color)
                    await dataStore.loadAll()
                }
            }
            .sheet(item: $editingSubscription) { sub in
                EditSubscriptionFormView(subscription: sub) {
                    await dataStore.loadAll()
                }
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
                    Text(days == 0 ? "Сегодня" : "через \(days) дн.")
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
        .background(Color(.systemBackground))
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
        case .weekly: "Еженедельно"
        case .monthly: "Ежемесячно"
        case .quarterly: "Ежеквартально"
        case .yearly: "Ежегодно"
        case .custom: "Произвольный"
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
    @State private var selectedColor: String = "#60A5FA"
    @State private var reminderDays: Int = 1
    @State private var isSaving = false

    private static let reminderOptions = [0, 1, 2, 3, 5, 7, 14, 30]
    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]
    private let repo = SubscriptionTrackerRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section("Подписка") {
                    TextField("Название", text: $name)
                    TextField("Сумма", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("Период", selection: $period) {
                        Text("Месяц").tag(BillingPeriod.monthly)
                        Text("Квартал").tag(BillingPeriod.quarterly)
                        Text("Год").tag(BillingPeriod.yearly)
                    }
                }

                Section("Напоминание") {
                    Picker("Напомнить", selection: $reminderDays) {
                        Text("В день списания").tag(0)
                        Text("За 1 день").tag(1)
                        Text("За 2 дня").tag(2)
                        Text("За 3 дня").tag(3)
                        Text("За 5 дней").tag(5)
                        Text("За 7 дней").tag(7)
                        Text("За 14 дней").tag(14)
                        Text("За 30 дней").tag(30)
                    }
                }

                Section("Цвет") {
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
            .navigationTitle("Редактировать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
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
            reminder_days: reminderDays
        )
        try? await repo.update(id: subscription.id, input)
        await onSave()
        dismiss()
    }
}
