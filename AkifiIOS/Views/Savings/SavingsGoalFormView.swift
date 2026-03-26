import SwiftUI

struct SavingsGoalFormView: View {
    @Environment(\.dismiss) private var dismiss

    let accounts: [Account]
    let onSave: (String, String, String, Int64, String?, String?) async -> Void

    @State private var name = ""
    @State private var targetAmountText = ""
    @State private var selectedIcon = "🎯"
    @State private var selectedColor = "#4ADE80"
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(86400 * 90)
    @State private var selectedAccountId: String?
    @State private var isSaving = false

    private let icons = ["🎯", "🏠", "🚗", "✈️", "💻", "📱", "🎓", "💍", "🏥", "🎮", "🏖️", "💰", "🎁", "📚", "🏋️", "🎵"]
    private let colors = ["#4ADE80", "#60A5FA", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#34D399", "#F87171", "#38BDF8", "#C084FC"]

    private var isValid: Bool {
        !name.isEmpty && !targetAmountText.isEmpty && (Decimal(string: targetAmountText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Цель") {
                    TextField("Название", text: $name)
                    TextField("Целевая сумма", text: $targetAmountText)
                        .keyboardType(.decimalPad)
                }

                Section("Иконка") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Text(icon)
                                .font(.title2)
                                .frame(width: 40, height: 40)
                                .background(selectedIcon == icon ? Color(hex: selectedColor).opacity(0.3) : .clear)
                                .clipShape(Circle())
                                .onTapGesture { selectedIcon = icon }
                        }
                    }
                }

                Section("Цвет") {
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

                Section("Дедлайн") {
                    Toggle("Установить дедлайн", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Дата", selection: $deadline, in: Date()..., displayedComponents: .date)
                    }
                }

                if !accounts.isEmpty {
                    Section("Счёт") {
                        Picker("Привязать к счёту", selection: $selectedAccountId) {
                            Text("Не привязан").tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Новая цель")
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
        guard let decimal = Decimal(string: targetAmountText) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let deadlineStr = hasDeadline ? df.string(from: deadline) : nil
        await onSave(name, selectedIcon, selectedColor, amountCents, deadlineStr, selectedAccountId)
        dismiss()
    }
}
