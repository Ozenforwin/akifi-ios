import SwiftUI

struct BudgetFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let accounts: [Account]
    let onSave: (String, Int64, BillingPeriod, [String]?, String?, Bool, Double?) async -> Void

    @State private var name = ""
    @State private var amountText = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedCategories: Set<String> = []
    @State private var selectedAccountId: String?
    @State private var rolloverEnabled = false
    @State private var alertThreshold: Double = 0.8
    @State private var isSaving = false

    private var expenseCategories: [Category] {
        categories.filter { $0.type == .expense }
    }

    private var isValid: Bool {
        !name.isEmpty && !amountText.isEmpty && (Decimal(string: amountText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Основное") {
                    TextField("Название бюджета", text: $name)
                    TextField("Сумма", text: $amountText)
                        .keyboardType(.decimalPad)

                    Picker("Период", selection: $period) {
                        Text("Месяц").tag(BillingPeriod.monthly)
                        Text("Квартал").tag(BillingPeriod.quarterly)
                        Text("Год").tag(BillingPeriod.yearly)
                    }
                }

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
                                            .foregroundStyle(.green)
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

                Section("Настройки") {
                    Toggle("Перенос остатка", isOn: $rolloverEnabled)

                    VStack(alignment: .leading) {
                        Text("Предупреждение при \(Int(alertThreshold * 100))%")
                            .font(.subheadline)
                        Slider(value: $alertThreshold, in: 0.5...1.0, step: 0.05)
                            .tint(.orange)
                    }
                }
            }
            .navigationTitle("Новый бюджет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        Task { await save() }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        guard let decimalAmount = Decimal(string: amountText) else { return }
        let amountInCents = Int64(truncating: (decimalAmount * 100) as NSDecimalNumber)
        let cats = selectedCategories.isEmpty ? nil : Array(selectedCategories)
        await onSave(name, amountInCents, period, cats, selectedAccountId, rolloverEnabled, alertThreshold)
        dismiss()
    }
}
