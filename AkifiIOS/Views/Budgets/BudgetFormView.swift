import SwiftUI

struct BudgetFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let accounts: [Account]
    let editingBudget: Budget?
    let onSave: () async -> Void

    @State private var budgetName = ""
    @State private var budgetDescription = ""
    @State private var calculatorState = CalculatorState()
    @State private var period: BillingPeriod = .monthly
    @State private var budgetType: BudgetType = .hard
    @State private var selectedCategories: Set<String> = []
    @State private var selectedAccountId: String?
    @State private var rolloverEnabled = false
    @State private var alertThresholds: [Int] = [80]
    @State private var showCategoryPicker = false
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
                // Name & description
                Section(String(localized: "common.name")) {
                    TextField(String(localized: "budget.budgetName"), text: $budgetName)
                    TextField(String(localized: "budget.descriptionOptional"), text: $budgetDescription)
                }

                // Budget Type
                Section {
                    Picker(String(localized: "common.type"), selection: $budgetType) {
                        ForEach(BudgetType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(budgetType.description)
                }

                // Amount
                Section(String(localized: "common.amount")) {
                    CalculatorKeyboardView(state: calculatorState)
                }

                // Period (DB only supports monthly, weekly, custom)
                Section(String(localized: "common.period")) {
                    Picker(String(localized: "common.period"), selection: $period) {
                        Text(String(localized: "period.week")).tag(BillingPeriod.weekly)
                        Text(String(localized: "period.monthShort")).tag(BillingPeriod.monthly)
                        Text(String(localized: "period.customRange")).tag(BillingPeriod.custom)
                    }

                    if period == .custom {
                        DatePicker(String(localized: "common.start"), selection: $customStartDate, displayedComponents: .date)
                        DatePicker(String(localized: "common.end"), selection: $customEndDate, displayedComponents: .date)
                    }
                }

                // Categories — compact collapsible
                Section(String(localized: "budget.categories")) {
                    Button {
                        showCategoryPicker.toggle()
                    } label: {
                        HStack {
                            if selectedCategories.isEmpty {
                                Text(String(localized: "budget.allCategories"))
                                    .foregroundStyle(.primary)
                            } else {
                                let icons = expenseCategories.filter { selectedCategories.contains($0.id) }.map(\.icon).prefix(5).joined()
                                Text(icons)
                                Text("\(selectedCategories.count) выбрано")
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Image(systemName: showCategoryPicker ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if showCategoryPicker {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                            ForEach(expenseCategories) { category in
                                let isSelected = selectedCategories.contains(category.id)
                                Button {
                                    if isSelected {
                                        selectedCategories.remove(category.id)
                                    } else {
                                        selectedCategories.insert(category.id)
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(category.icon)
                                            .font(.title3)
                                        Text(category.name)
                                            .font(.system(size: 9))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? Color.accent.opacity(0.15) : Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(isSelected ? Color.accent : .clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Account
                if !accounts.isEmpty {
                    Section(String(localized: "common.account")) {
                        Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                            Text(String(localized: "budget.allAccounts")).tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }

                // Settings
                Section(String(localized: "common.settings")) {
                    Toggle(String(localized: "budget.rollover"), isOn: $rolloverEnabled)

                    // Alert thresholds
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "budget.alertThresholds"))
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
            .navigationTitle(isEditing ? String(localized: "common.editing") : String(localized: "budget.newBudget"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "common.save") : String(localized: "common.create")) {
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
        budgetName = budget.budgetName ?? ""
        budgetDescription = budget.budgetDescription ?? ""
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
            errorMessage = String(localized: "common.enterAmount")
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
                    name: budgetName.isEmpty ? nil : budgetName,
                    description: budgetDescription.isEmpty ? nil : budgetDescription,
                    amount: amountForDB,
                    period_type: period.rawValue,
                    category_ids: cats ?? [],
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
                let userId = try await SupabaseManager.shared.client.auth.session.user.id.uuidString
                let input = CreateBudgetInput(
                    user_id: userId,
                    name: budgetName.isEmpty ? nil : budgetName,
                    description: budgetDescription.isEmpty ? nil : budgetDescription,
                    amount: amountForDB,
                    period_type: period.rawValue,
                    category_ids: cats ?? [],
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
