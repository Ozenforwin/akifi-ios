import SwiftUI

struct BudgetFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let accounts: [Account]
    let editingBudget: Budget?
    let onSave: () async -> Void

    @State private var calculatorState = CalculatorState()
    @State private var period: BillingPeriod = .monthly
    @State private var budgetType: BudgetType = .hard
    @State private var selectedCategories: Set<String> = []
    @State private var selectedAccountId: String?
    @State private var rolloverEnabled = false
    @State private var alertThresholds: [Int] = [80]
    @State private var customStartDate = Date()
    @State private var customEndDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())!
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let budgetRepo = BudgetRepository()

    init(categories: [Category], accounts: [Account], editingBudget: Budget? = nil, onSave: @escaping () async -> Void) {
        self.categories = categories
        self.accounts = accounts
        self.editingBudget = editingBudget
        self.onSave = onSave
    }

    private var isEditing: Bool { editingBudget != nil }

    private var expenseCategories: [Category] {
        categories.filter { $0.type == .expense }
    }

    private var isValid: Bool {
        let amount = calculatorState.getResult() ?? 0
        return amount > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                // Budget Type
                Section {
                    Picker("Тип", selection: $budgetType) {
                        ForEach(BudgetType.allCases, id: \.self) { type in
                            VStack(alignment: .leading) {
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Тип бюджета")
                } footer: {
                    Text(budgetType.description)
                }

                // Amount
                Section("Сумма") {
                    CalculatorKeyboardView(state: calculatorState)
                }

                // Period
                Section("Период") {
                    Picker("Период", selection: $period) {
                        ForEach(BillingPeriod.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }

                    if period == .custom {
                        DatePicker("Начало", selection: $customStartDate, displayedComponents: .date)
                        DatePicker("Конец", selection: $customEndDate, displayedComponents: .date)
                    }
                }

                // Categories
                Section("Категории") {
                    if expenseCategories.isEmpty {
                        Text("Нет категорий расходов")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(expenseCategories) { category in
                            Button {
                                if selectedCategories.contains(category.id) {
                                    selectedCategories.remove(category.id)
                                } else {
                                    selectedCategories.insert(category.id)
                                }
                            } label: {
                                HStack {
                                    Text(category.icon)
                                    Text(category.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedCategories.contains(category.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accent)
                                    }
                                }
                            }
                        }
                    }

                    if selectedCategories.isEmpty {
                        Text("Все категории расходов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Account
                if !accounts.isEmpty {
                    Section("Счёт") {
                        Picker("Счёт", selection: $selectedAccountId) {
                            Text("Все счета").tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }

                // Settings
                Section("Настройки") {
                    Toggle("Перенос остатка", isOn: $rolloverEnabled)

                    // Alert thresholds
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Пороги предупреждений")
                                .font(.subheadline)
                            Spacer()
                            Button {
                                if alertThresholds.count < 4 {
                                    let next = (alertThresholds.last ?? 70) + 10
                                    alertThresholds.append(min(next, 100))
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.accent)
                            }
                            .disabled(alertThresholds.count >= 4)
                        }

                        ForEach(alertThresholds.indices, id: \.self) { index in
                            HStack {
                                Text("\(alertThresholds[index])%")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 40)
                                Slider(
                                    value: Binding(
                                        get: { Double(alertThresholds[index]) },
                                        set: { alertThresholds[index] = Int($0) }
                                    ),
                                    in: 10...100,
                                    step: 5
                                )
                                .tint(.orange)

                                if alertThresholds.count > 1 {
                                    Button {
                                        alertThresholds.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.red)
                                            .font(.caption)
                                    }
                                }
                            }
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
            .navigationTitle(isEditing ? "Редактирование" : "Новый бюджет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Сохранить" : "Создать") {
                        Task { await save() }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .onAppear { prefillIfEditing() }
        }
    }

    private func prefillIfEditing() {
        guard let budget = editingBudget else { return }
        calculatorState.setValue(budget.amount.displayAmount)
        period = budget.billingPeriod
        budgetType = budget.budgetTypeEnum
        selectedCategories = Set(budget.categoryIds ?? [])
        selectedAccountId = budget.accountId
        rolloverEnabled = budget.rolloverEnabled
        alertThresholds = budget.alertThresholds ?? [80]
        if let start = budget.customStartDate {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            customStartDate = df.date(from: start) ?? Date()
        }
        if let end = budget.customEndDate {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            customEndDate = df.date(from: end) ?? Date()
        }
    }

    private func save() async {
        guard let decimalAmount = calculatorState.getResult(), decimalAmount > 0 else {
            errorMessage = "Введите сумму"
            return
        }

        isSaving = true
        let amountForDB = decimalAmount // CalculatorState returns display amount, convert to rubles for DB
        let cats = selectedCategories.isEmpty ? nil : Array(selectedCategories)
        let accountIds = selectedAccountId.map { [$0] }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        do {
            if let budget = editingBudget {
                // Update existing budget
                let input = UpdateBudgetInput(
                    amount: amountForDB,
                    period_type: period.rawValue,
                    category_ids: cats,
                    account_ids: accountIds,
                    rollover_enabled: rolloverEnabled,
                    alert_thresholds: alertThresholds,
                    budget_type: budgetType.rawValue,
                    custom_start_date: period == .custom ? df.string(from: customStartDate) : nil,
                    custom_end_date: period == .custom ? df.string(from: customEndDate) : nil
                )
                try await budgetRepo.update(id: budget.id, input)
            } else {
                // Create new budget
                let input = CreateBudgetInput(
                    amount: amountForDB,
                    period_type: period.rawValue,
                    category_ids: cats,
                    account_ids: accountIds,
                    rollover_enabled: rolloverEnabled,
                    alert_thresholds: alertThresholds,
                    budget_type: budgetType.rawValue,
                    custom_start_date: period == .custom ? df.string(from: customStartDate) : nil,
                    custom_end_date: period == .custom ? df.string(from: customEndDate) : nil
                )
                _ = try await budgetRepo.create(input)
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }
}
