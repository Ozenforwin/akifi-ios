import SwiftUI

struct ContributionSheetView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let goal: SavingsGoal
    /// (amount kopecks, type, note, counter-account id — see
    /// `SavingsViewModel.accountLegs`). Throws (V7): a failure shows here
    /// and the sheet stays open.
    let onContribute: (Int64, ContributionType, String?, String?) async throws -> Void

    @State private var amountText = ""
    @State private var type: ContributionType = .contribution
    @State private var note = ""
    @State private var isSaving = false
    @State private var saveError: String?
    /// Where a contribution comes from / a withdrawal goes to (M2). nil =
    /// contribution: the money is already on the goal's account;
    /// withdrawal: it leaves that account.
    @State private var counterAccountId: String?

    /// "0,5" is 50 kopecks, not 0 — and 0 is not a contribution (V7).
    private var parsedAmount: Int64? {
        guard let kopecks = DecimalInput.kopecks(amountText), kopecks > 0 else { return nil }
        return kopecks
    }

    /// The account the goal's money lives on.
    private var linkedAccount: Account? {
        guard let id = goal.accountId else { return nil }
        return appViewModel.dataStore.accounts.first { $0.id == id }
    }

    private var counterCandidates: [Account] {
        guard let linked = linkedAccount else { return [] }
        return appViewModel.dataStore.accounts.filter { $0.id != linked.id }
    }

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

                if let linked = linkedAccount, !counterCandidates.isEmpty {
                    Section(type == .withdrawal ? String(localized: "transfer.to") : String(localized: "transfer.from")) {
                        // One Text per row: menu pickers drop extra children.
                        Picker(type == .withdrawal ? String(localized: "transfer.to") : String(localized: "transfer.from"),
                               selection: $counterAccountId) {
                            Text(type == .withdrawal
                                 ? String(format: String(localized: "contribution.counter.none.withdrawal"), linked.name)
                                 : String(format: String(localized: "contribution.counter.none.deposit"), linked.name))
                                .tag(String?.none)
                            ForEach(counterCandidates) { acc in
                                Text("\(acc.icon) \(acc.name)").tag(Optional(acc.id))
                            }
                        }
                        .frame(minHeight: 44)
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
                    .disabled(parsedAmount == nil || isSaving)
                }
            }
            .errorAlert($saveError)
        }
    }

    private func save() async {
        guard !isSaving, let amountCents = parsedAmount else { return }
        isSaving = true
        defer { isSaving = false }
        let noteStr = note.isEmpty ? nil : note
        do {
            try await onContribute(amountCents, type, noteStr, counterAccountId)
        } catch {
            HapticManager.error()
            saveError = error.localizedDescription
            return
        }
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
                    .foregroundStyle(.secondary)
                Text(appViewModel.currencyManager.formatAmount(amount.displayAmount))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        // Several buttons share one form row; an explicit style (not the
        // row-wide default) keeps each tap to its own button.
        .buttonStyle(.bordered)
        .tint(.secondary)
        .foregroundStyle(.primary)
    }
}
