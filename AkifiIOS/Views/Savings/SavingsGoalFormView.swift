import SwiftUI

struct SavingsGoalFormView: View {
    @Environment(\.dismiss) private var dismiss

    let accounts: [Account]
    let onSave: (String, String, String, Int64, String?, String?) async -> Void
    let editingGoal: SavingsGoal?

    @State private var name = ""
    @State private var targetAmountText = ""
    @State private var selectedIcon = "🎯"
    @State private var selectedColor = "#4ADE80"
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(86400 * 90)
    @State private var selectedAccountId: String?
    @State private var interestRate = ""
    @State private var interestType = "annual"
    @State private var interestCompound = true
    @State private var showInterest = false
    @State private var isSaving = false

    private let icons = ["🎯", "🏠", "🚗", "✈️", "💻", "📱", "🎓", "💍", "🏥", "🎮",
                         "🏖️", "💰", "🎁", "📚", "🏋️", "🎵", "👶", "🐕", "💎", "🏦"]
    private let colors = ["#4ADE80", "#60A5FA", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C",
                          "#34D399", "#F87171", "#38BDF8", "#C084FC", "#6366F1", "#EC4899",
                          "#14B8A6", "#EF4444", "#8B5CF6", "#06B6D4"]

    private var isValid: Bool {
        !name.isEmpty && !targetAmountText.isEmpty && (Decimal(string: targetAmountText) ?? 0) > 0
    }

    private var isEditing: Bool { editingGoal != nil }

    init(accounts: [Account], editingGoal: SavingsGoal? = nil, onSave: @escaping (String, String, String, Int64, String?, String?) async -> Void) {
        self.accounts = accounts
        self.editingGoal = editingGoal
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "savings.goal")) {
                    TextField(String(localized: "common.name"), text: $name)
                    TextField(String(localized: "savings.targetAmount"), text: $targetAmountText)
                        .keyboardType(.decimalPad)
                }

                Section(String(localized: "savings.icon")) {
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

                Section(String(localized: "savings.color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if selectedColor == color {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { selectedColor = color }
                        }
                    }
                }

                Section(String(localized: "savings.deadline")) {
                    Toggle(String(localized: "savings.setDeadline"), isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker(String(localized: "common.date"), selection: $deadline, in: Date()..., displayedComponents: .date)
                    }
                }

                // Interest rate (collapsible)
                Section {
                    DisclosureGroup(String(localized: "savings.interest"), isExpanded: $showInterest) {
                        TextField(String(localized: "savings.interestRate"), text: $interestRate)
                            .keyboardType(.decimalPad)
                        Picker(String(localized: "savings.interestType"), selection: $interestType) {
                            Text(String(localized: "savings.annual")).tag("annual")
                            Text(String(localized: "savings.monthly")).tag("monthly")
                        }
                        .pickerStyle(.segmented)
                        Toggle(String(localized: "savings.compound"), isOn: $interestCompound)
                    }
                }

                if !accounts.isEmpty {
                    Section(String(localized: "common.account")) {
                        Picker(String(localized: "savings.linkAccount"), selection: $selectedAccountId) {
                            Text(String(localized: "savings.notLinked")).tag(nil as String?)
                            ForEach(accounts) { account in
                                Text("\(account.icon) \(account.name)").tag(account.id as String?)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "savings.editGoal") : String(localized: "savings.newGoal"))
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
            .onAppear { prefill() }
        }
    }

    private func prefill() {
        guard let goal = editingGoal else { return }
        name = goal.name
        targetAmountText = "\(goal.targetAmount.displayAmount)"
        selectedIcon = goal.icon
        selectedColor = goal.color
        selectedAccountId = goal.accountId
        if let dl = goal.deadline {
            hasDeadline = true
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            deadline = df.date(from: dl) ?? Date()
        }
        if let rate = goal.interestRate, rate > 0 {
            showInterest = true
            interestRate = "\(rate)"
            interestType = goal.interestType ?? "annual"
            interestCompound = goal.interestCompound ?? true
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
