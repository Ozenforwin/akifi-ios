import SwiftUI

struct ContributionSheetView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let goal: SavingsGoal
    let onContribute: (Int64, ContributionType, String?) async -> Void

    @State private var amountText = ""
    @State private var type: ContributionType = .contribution
    @State private var note = ""
    @State private var isSaving = false

    private var remaining: Int64 {
        max(goal.targetAmount - goal.currentAmount, 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "common.type"), selection: $type) {
                        Text(String(localized: "contribution.deposit")).tag(ContributionType.contribution)
                        Text(String(localized: "contribution.withdraw")).tag(ContributionType.withdrawal)
                    }
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "transfer.amount")) {
                    TextField(String(localized: "transfer.amount"), text: $amountText)
                        .keyboardType(.decimalPad)

                    if type == .contribution {
                        HStack(spacing: 8) {
                            QuickAmountChip(label: String(localized: "contribution.remaining"), amount: remaining) { amountText = formatForInput(remaining) }
                            QuickAmountChip(label: "50%", amount: remaining / 2) { amountText = formatForInput(remaining / 2) }
                            QuickAmountChip(label: "25%", amount: remaining / 4) { amountText = formatForInput(remaining / 4) }
                        }
                    }
                }

                Section(String(localized: "contribution.note")) {
                    TextField(String(localized: "contribution.optional"), text: $note)
                }

                Section {
                    HStack {
                        Text(String(localized: "contribution.currentProgress"))
                        Spacer()
                        Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                            .foregroundStyle(.secondary)
                        Text("/ \(appViewModel.currencyManager.formatAmount(goal.targetAmount.displayAmount))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(type == .contribution ? String(localized: "contribution.deposit") : String(localized: "contribution.withdraw"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) {
                        Task { await save() }
                    }
                    .disabled(amountText.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        guard let decimal = Decimal(string: amountText) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        let noteStr = note.isEmpty ? nil : note
        await onContribute(amountCents, type, noteStr)
        dismiss()
    }

    private func formatForInput(_ cents: Int64) -> String {
        let value = Decimal(cents) / 100
        return "\(value)"
    }
}

struct QuickAmountChip: View {
    @Environment(AppViewModel.self) private var appViewModel
    let label: String
    let amount: Int64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.caption2)
                Text(appViewModel.currencyManager.formatAmount(amount.displayAmount))
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
