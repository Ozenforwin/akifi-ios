import SwiftUI

/// Sheet for adding a contribution (top-up) to an existing active deposit.
/// Analogous to `ContributionSheetView` for savings goals.
///
/// The new lot starts its own compounding clock on `contributed_at =
/// today`, so the accrual is automatically correct — no need to
/// reconcile the historical aggregate.
struct DepositContributeSheet: View {
    let deposit: Deposit
    let depositAccount: Account
    let viewModel: DepositsViewModel

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String = ""
    @State private var sourceAccountId: String?
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var depositCurrency: CurrencyCode {
        CurrencyCode(rawValue: depositAccount.currency.uppercased()) ?? .rub
    }

    private var personalSourceAccounts: [Account] {
        dataStore.accounts.filter { $0.accountType != .deposit }
    }

    private var sourceAccount: Account? {
        personalSourceAccounts.first { $0.id == sourceAccountId }
    }

    private var amountKopecks: Int64 {
        parseKopecks(amountText)
    }

    private var crossCurrencyInfo: (sourceKopecks: Int64, fxRate: Decimal)? {
        guard let src = sourceAccount else { return nil }
        let srcCcy = CurrencyCode(rawValue: src.currency.uppercased()) ?? .rub
        guard srcCcy != depositCurrency else { return nil }
        let depositAmountUnits = Decimal(amountKopecks) / 100
        let sourceAmountUnits = cm.convertToAccountCurrency(depositAmountUnits, accountCurrency: srcCcy)
        let sourceKopecks = Int64(truncating: (sourceAmountUnits * 100) as NSDecimalNumber)
        guard sourceAmountUnits > 0 else { return (sourceKopecks, 0) }
        let rate = depositAmountUnits / sourceAmountUnits
        return (sourceKopecks, rate)
    }

    private var isValid: Bool {
        amountKopecks > 0 && sourceAccountId != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "deposit.contribute.title")) {
                    HStack {
                        TextField(String(localized: "deposit.form.amount"), text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(depositCurrency.symbol)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "deposit.form.source")) {
                    Picker(String(localized: "deposit.form.source"), selection: $sourceAccountId) {
                        Text(String(localized: "deposit.form.pickSource")).tag(String?.none)
                        ForEach(personalSourceAccounts) { acc in
                            Text("\(acc.icon) \(acc.name) (\(acc.currency.uppercased()))")
                                .tag(Optional(acc.id))
                        }
                    }
                    if let info = crossCurrencyInfo, let src = sourceAccount, info.sourceKopecks > 0 {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "deposit.form.crossCurrencyHint"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatKopecks(info.sourceKopecks, currency: CurrencyCode(rawValue: src.currency.uppercased()) ?? .rub))
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "deposit.contribute"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.save")) {
                        Task { await save() }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .onAppear {
                if sourceAccountId == nil {
                    sourceAccountId = personalSourceAccounts.first?.id
                }
            }
        }
    }

    private func save() async {
        guard let src = sourceAccount else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let cross = crossCurrencyInfo
            try await viewModel.contribute(
                to: deposit,
                depositAccount: depositAccount,
                amountInDeposit: amountKopecks,
                sourceAccount: src,
                sourceAmount: cross?.sourceKopecks,
                fxRate: cross?.fxRate,
                dataStore: dataStore
            )
            HapticManager.success()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseKopecks(_ text: String) -> Int64 {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: cleaned) else { return 0 }
        let kopecks = decimal * 100
        var rounded = Decimal()
        var src = kopecks
        NSDecimalRound(&rounded, &src, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    private func formatKopecks(_ kopecks: Int64, currency: CurrencyCode) -> String {
        let decimal = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = currency.decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = " "
        let formatted = f.string(from: decimal as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
    }
}
