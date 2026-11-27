import SwiftUI

/// «Ваш долг перед счётом» on a shared account (settlement v2
/// `personal_debts`, contract §B5/§B6): what members owe the ACCOUNT for
/// personal spending paid from its own money. «Погасить» only on my own
/// entry; owners and editors also see the others'. Content card, no glass.
struct PersonalDebtCard: View {
    let account: Account
    let viewModel: SettlementViewModel

    @Environment(AppViewModel.self) private var appViewModel
    @State private var showRepay = false

    private var dataStore: DataStore { appViewModel.dataStore }
    private var me: String? { dataStore.profile?.id.lowercased() }

    private var myRole: AccountRole? {
        PersonalDebtRules.role(of: me, account: account, members: viewModel.members)
    }

    /// Entries with any personal activity (contract §B6 filter).
    private var visible: [SettlementCalculator.PersonalDebt] {
        viewModel.personalDebts.filter { $0.expenses > 0 || $0.repaid > 0 }
    }

    private var mine: SettlementCalculator.PersonalDebt? {
        visible.first { $0.userId.lowercased() == me }
    }

    private var others: [SettlementCalculator.PersonalDebt] {
        guard PersonalDebtRules.canMarkOthers(myRole: myRole) else { return [] }
        return visible.filter { $0.userId.lowercased() != me && $0.owed > 0 }
    }

    var body: some View {
        if mine != nil || !others.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "personalDebt.card.title"))
                    .font(.headline)

                if let mine {
                    myRow(mine)
                }

                if !others.isEmpty {
                    if mine != nil { Divider() }
                    ForEach(others) { debt in
                        HStack {
                            Text(name(debt.userId))
                                .font(.subheadline)
                            if !debt.isMember {
                                Text(String(localized: "personalDebt.formerMember"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(amount(debt.owed))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.expense)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .sheet(isPresented: $showRepay) {
                RepayPersonalDebtSheet(sharedAccount: account, owed: mine?.owed ?? 0) {
                    await viewModel.load(sharedAccountId: account.id, dataStore: dataStore, currencyManager: appViewModel.currencyManager)
                }
            }
        }
    }

    @ViewBuilder
    private func myRow(_ mine: SettlementCalculator.PersonalDebt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "personalDebt.card.mine"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(amount(mine.owed))
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(mine.owed > 0 ? Color.expense : .secondary)
            Text(String(localized: "personalDebt.card.caption \(amount(mine.expenses)) \(amount(mine.repaid))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if mine.owed > 0 {
                Button {
                    showRepay = true
                } label: {
                    Label(String(localized: "personalDebt.repay"), systemImage: "arrow.uturn.left.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.akifiPrimary)
                .controlSize(.large)
                .disabled(!viewModel.canRecordSettlements)
                if !viewModel.canRecordSettlements {
                    Text(String(localized: "settlement.offline.approximate"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func amount(_ minor: Int64) -> String {
        DebtFormat.amount(minor, currency: account.currency, cm: appViewModel.currencyManager)
    }

    private func name(_ userId: String) -> String {
        dataStore.profilesMap[userId]?.fullName
            ?? dataStore.profilesMap.first { $0.key.lowercased() == userId.lowercased() }?.value.fullName
            ?? String(localized: "personalDebt.member.unknown")
    }
}

/// «Погасить»: a manual transfer from one of my own money accounts into the
/// shared account; the income leg carries `personal_debt_user_id = me`.
struct RepayPersonalDebtSheet: View {
    let sharedAccount: Account
    /// What I owe now, minor units of the shared account's currency.
    let owed: Int64
    let onSaved: () async -> Void

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var fromAccountId: String?
    @State private var date = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmOverpay = false

    private var dataStore: DataStore { appViewModel.dataStore }
    private var me: String? { dataStore.profile?.id.lowercased() }

    /// My own money accounts, not the shared one (contract §B5).
    private var sources: [Account] {
        dataStore.accounts.filter { $0.id != sharedAccount.id && $0.userId.lowercased() == me }
    }

    private var amount: Decimal? { DebtFormat.parseAmount(amountText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "personalDebt.card.mine")) {
                        Text(DebtFormat.amount(owed, currency: sharedAccount.currency, cm: appViewModel.currencyManager))
                            .monospacedDigit()
                    }
                }
                Section(String(localized: "common.amount")) {
                    HStack {
                        TextField(String(localized: "debts.amount.placeholder"), text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.title2.monospacedDigit())
                        Text(sharedAccount.currencyCode.symbol)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker(String(localized: "debts.account.from"), selection: $fromAccountId) {
                        ForEach(sources) { acc in
                            Text("\(acc.icon) \(acc.name)").tag(acc.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    DatePicker(String(localized: "common.date"), selection: $date, displayedComponents: .date)
                } footer: {
                    Text(String(localized: "personalDebt.repay.footer \(sharedAccount.name)"))
                }
                if sources.isEmpty {
                    Section {
                        Text(String(localized: "personalDebt.repay.noAccounts"))
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(Color.expense)
                    }
                }
            }
            .navigationTitle(String(localized: "personalDebt.repay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save")) {
                        if let amount, amount.kopecks > owed {
                            confirmOverpay = true
                        } else {
                            Task { await save() }
                        }
                    }
                    .disabled(amount == nil || fromAccountId == nil || isSaving)
                }
            }
            .alert(String(localized: "personalDebt.overpay.title"), isPresented: $confirmOverpay) {
                Button(String(localized: "debts.flip.confirm")) { Task { await save() } }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "personalDebt.overpay.message"))
            }
            .onAppear {
                if amountText.isEmpty, owed > 0 { amountText = DebtFormat.fieldText(owed) }
                if fromAccountId == nil { fromAccountId = (sources.first(where: \.isPrimary) ?? sources.first)?.id }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let amount, let from = sources.first(where: { $0.id == fromAccountId }) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appViewModel.debts.repayPersonalDebt(
                amount: amount, entryCurrency: sharedAccount.currencyCode, sharedAccount: sharedAccount,
                fromAccount: from, date: date, dataStore: dataStore, currencyManager: appViewModel.currencyManager
            )
            HapticManager.success()
            await onSaved()
            dismiss()
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }
    }
}
