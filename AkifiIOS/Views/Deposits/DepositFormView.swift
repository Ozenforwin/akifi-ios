import SwiftUI

/// Deposit creation form. Collects everything needed to auto-create the
/// tied Account + Deposit + first Contribution + transfer pair in one
/// save operation.
///
/// Rate is immutable after creation — this form is intentionally
/// create-only; no edit path.
struct DepositFormView: View {
    let viewModel: DepositsViewModel

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var currency: CurrencyCode = .rub
    @State private var amountText: String = ""
    @State private var rateText: String = "12"
    @State private var frequency: CompoundFrequency = .monthly
    @State private var startDate: Date = Date()
    @State private var hasEndDate: Bool = true
    @State private var endDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var sourceAccountId: String?
    @State private var returnAccountId: String?
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    /// Candidates for the source picker — only personal (non-deposit)
    /// accounts the user can spend from.
    private var personalSourceAccounts: [Account] {
        dataStore.accounts.filter { $0.accountType != .deposit }
    }

    private var sourceAccount: Account? {
        personalSourceAccounts.first { $0.id == sourceAccountId }
    }

    private var amountKopecks: Int64 {
        parseKopecks(amountText)
    }

    /// Decimal representation of the annual rate (e.g. 12.5 → Decimal(12.5)).
    private var rateDecimal: Decimal {
        Decimal(string: rateText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// When source currency != deposit currency, convert at current FX to
    /// show the user what will be credited. Returns (sourceKopecks in
    /// source currency, fxRate) used by the save flow.
    private var crossCurrencyInfo: (sourceKopecks: Int64, fxRate: Decimal)? {
        guard let src = sourceAccount else { return nil }
        let srcCcy = CurrencyCode(rawValue: src.currency.uppercased()) ?? .rub
        guard srcCcy != currency else { return nil }
        // amountKopecks is in DEPOSIT currency. Convert to source currency
        // using the ExchangeRateService's USD-pivot rates via CurrencyManager.
        let depositAmountUnits = Decimal(amountKopecks) / 100
        let sourceAmountUnits = cm.convertToAccountCurrency(depositAmountUnits, accountCurrency: srcCcy)
        let sourceKopecks = Int64(truncating: (sourceAmountUnits * 100) as NSDecimalNumber)
        // fxRate: units of deposit per unit of source
        // computed as (deposit / source). Avoid div-by-zero.
        guard sourceAmountUnits > 0 else { return (sourceKopecks, 0) }
        let rate = depositAmountUnits / sourceAmountUnits
        return (sourceKopecks, rate)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && amountKopecks > 0
            && rateDecimal >= 0
            && sourceAccountId != nil
            && (!hasEndDate || endDate > startDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "deposit.form.section.info")) {
                    TextField(String(localized: "deposit.form.name"), text: $name)
                    Picker(String(localized: "common.currency"), selection: $currency) {
                        ForEach(CurrencyCode.allCases, id: \.self) { code in
                            Text("\(code.symbol) \(code.rawValue)").tag(code)
                        }
                    }
                }

                Section(String(localized: "deposit.form.section.initialDeposit")) {
                    HStack {
                        TextField(String(localized: "deposit.form.amount"), text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(currency.symbol)
                            .foregroundStyle(.secondary)
                    }
                    sourcePicker
                    if let info = crossCurrencyInfo, let src = sourceAccount, info.sourceKopecks > 0 {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "deposit.form.crossCurrencyHint"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(formatKopecks(info.sourceKopecks, currency: CurrencyCode(rawValue: src.currency.uppercased()) ?? .rub))")
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                }

                Section(String(localized: "deposit.form.section.terms")) {
                    HStack {
                        TextField(String(localized: "deposit.form.rate"), text: $rateText)
                            .keyboardType(.decimalPad)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                    Picker(String(localized: "deposit.form.frequency"), selection: $frequency) {
                        ForEach(CompoundFrequency.allCases, id: \.self) { freq in
                            Text(freq.localizedTitle).tag(freq)
                        }
                    }
                    DatePicker(
                        String(localized: "deposit.form.startDate"),
                        selection: $startDate,
                        displayedComponents: .date
                    )
                    Toggle(String(localized: "deposit.form.hasEndDate"), isOn: $hasEndDate.animation())
                    if hasEndDate {
                        DatePicker(
                            String(localized: "deposit.form.endDate"),
                            selection: $endDate,
                            in: startDate...,
                            displayedComponents: .date
                        )
                    }
                }

                Section(String(localized: "deposit.form.section.return")) {
                    returnPicker
                    Text(String(localized: "deposit.form.returnHint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "deposit.form.title"))
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
                currency = cm.dataCurrency
                if sourceAccountId == nil {
                    sourceAccountId = personalSourceAccounts.first?.id
                    returnAccountId = sourceAccountId
                }
            }
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        Picker(String(localized: "deposit.form.source"), selection: $sourceAccountId) {
            Text(String(localized: "deposit.form.pickSource")).tag(String?.none)
            ForEach(personalSourceAccounts) { acc in
                HStack {
                    Text(acc.icon)
                    Text(acc.name)
                    Text("(\(acc.currency.uppercased()))")
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(acc.id))
            }
        }
        .onChange(of: sourceAccountId) { _, newValue in
            // Default return = source, unless user explicitly chose otherwise.
            if returnAccountId == nil || !personalSourceAccounts.contains(where: { $0.id == returnAccountId }) {
                returnAccountId = newValue
            }
        }
    }

    @ViewBuilder
    private var returnPicker: some View {
        Picker(String(localized: "deposit.form.returnTo"), selection: $returnAccountId) {
            Text(String(localized: "deposit.form.pickReturn")).tag(String?.none)
            ForEach(personalSourceAccounts) { acc in
                HStack {
                    Text(acc.icon)
                    Text(acc.name)
                }
                .tag(Optional(acc.id))
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
            try await viewModel.create(
                name: name.trimmingCharacters(in: .whitespaces),
                currency: currency,
                rate: rateDecimal,
                frequency: frequency,
                startDate: startDate,
                endDate: hasEndDate ? endDate : nil,
                initialAmount: amountKopecks,
                sourceAccount: src,
                sourceAmount: cross?.sourceKopecks,
                fxRate: cross?.fxRate,
                returnToAccountId: returnAccountId,
                dataStore: dataStore,
                currencyManager: cm
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
