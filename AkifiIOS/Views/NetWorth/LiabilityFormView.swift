import SwiftUI

/// Create/edit form for a single liability. Fields mirror the DB columns:
/// name, category, current balance, original amount (optional), interest
/// rate %, currency, monthly payment (optional), end date (optional),
/// notes.
struct LiabilityFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    /// Throwing like `AssetFormView` (V4): a backend reject shows in an
    /// alert and the form stays open instead of closing on "success".
    let onSave: (CreateLiabilityInput) async throws -> Void
    let onUpdate: ((String, UpdateLiabilityInput) async throws -> Void)?
    let editingLiability: Liability?
    let initialCategory: LiabilityCategory?

    @State private var name: String = ""
    @State private var category: LiabilityCategory = .loan
    @State private var balanceText: String = ""
    @State private var originalText: String = ""
    @State private var interestRateText: String = ""
    @State private var currency: CurrencyCode = .rub
    @State private var monthlyPaymentText: String = ""
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = Date().addingTimeInterval(86400 * 365)
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var saveError: String?

    init(initialCategory: LiabilityCategory? = nil,
         editingLiability: Liability? = nil,
         onSave: @escaping (CreateLiabilityInput) async throws -> Void,
         onUpdate: ((String, UpdateLiabilityInput) async throws -> Void)? = nil) {
        self.initialCategory = initialCategory
        self.editingLiability = editingLiability
        self.onSave = onSave
        self.onUpdate = onUpdate
    }

    private var isEditing: Bool { editingLiability != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (DecimalInput.parse(balanceText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "liability.form.section.info")) {
                    TextField(String(localized: "liability.form.name"), text: $name)
                    categoryPicker
                }

                Section(String(localized: "liability.form.section.balance")) {
                    HStack {
                        TextField(String(localized: "liability.form.currentBalance"), text: $balanceText)
                            .keyboardType(.decimalPad)
                        ActiveCurrencyPicker(selection: $currency)
                    }
                    TextField(String(localized: "liability.form.originalAmount"), text: $originalText)
                        .keyboardType(.decimalPad)
                }

                Section(String(localized: "liability.form.section.terms")) {
                    TextField(String(localized: "liability.form.interestRate"), text: $interestRateText)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "liability.form.monthlyPayment"), text: $monthlyPaymentText)
                        .keyboardType(.decimalPad)
                    Toggle(String(localized: "liability.form.hasEndDate"), isOn: $hasEndDate.animation())
                    if hasEndDate {
                        DatePicker(
                            String(localized: "liability.form.endDate"),
                            selection: $endDate,
                            displayedComponents: .date
                        )
                    }
                }

                Section(String(localized: "liability.form.notes")) {
                    TextField(String(localized: "liability.form.notes.placeholder"), text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle(isEditing
                             ? String(localized: "liability.form.title.edit")
                             : String(localized: "liability.form.title.new"))
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
            .onAppear { prefillForEditing() }
            .errorAlert($saveError)
        }
    }

    @ViewBuilder
    private var categoryPicker: some View {
        Picker(String(localized: "liability.form.category"), selection: $category) {
            ForEach(LiabilityCategory.allCases, id: \.self) { cat in
                Label(cat.localizedTitle, systemImage: cat.symbol)
                    .tag(cat)
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let currentBalance = parseKopecks(balanceText)
        let original = parseOptionalKopecks(originalText)
        let monthly = parseOptionalKopecks(monthlyPaymentText)
        let rate = parseOptionalRate(interestRateText)
        let endString: String? = hasEndDate
            ? NetWorthSnapshotRepository.dateFormatter.string(from: endDate)
            : nil
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editing = editingLiability, let onUpdate {
            // Clearable fields go as `.some(value)`: a nil value is
            // written as NULL — the user removed it (V4). A bare
            // `cond ? nil : x` would type as the OUTER nil and be dropped.
            let update = UpdateLiabilityInput(
                name: name,
                category: category.rawValue,
                current_balance: currentBalance,
                original_amount: .some(original),
                interest_rate: .some(rate),
                currency: currency.code,
                icon: nil,
                color: nil,
                notes: .some(trimmedNotes.isEmpty ? nil : trimmedNotes),
                monthly_payment: .some(monthly),
                end_date: .some(endString)
            )
            do {
                try await onUpdate(editing.id, update)
            } catch {
                HapticManager.error()
                saveError = error.localizedDescription
                return
            }
        } else {
            let userId = (try? await SupabaseManager.shared.currentUserId()) ?? ""
            let input = CreateLiabilityInput(
                user_id: userId,
                name: name,
                category: category.rawValue,
                current_balance: currentBalance,
                original_amount: original,
                interest_rate: rate,
                currency: currency.code,
                icon: nil,
                color: nil,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                monthly_payment: monthly,
                end_date: endString
            )
            do {
                try await onSave(input)
            } catch {
                HapticManager.error()
                saveError = error.localizedDescription
                return
            }
        }

        HapticManager.success()
        dismiss()
    }

    private func parseKopecks(_ text: String) -> Int64 {
        DecimalInput.kopecks(text) ?? 0
    }

    private func parseOptionalKopecks(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let value = parseKopecks(trimmed)
        return value > 0 ? value : nil
    }

    /// APR input: "7.5" or "7,5" → 7.5. Clamps to NUMERIC(5,3) range
    /// (−99.999 … 99.999) — anything outside becomes nil.
    private func parseOptionalRate(_ text: String) -> Double? {
        guard let value = DecimalInput.parse(text).map({ NSDecimalNumber(decimal: $0).doubleValue }) else { return nil }
        guard abs(value) < 100 else { return nil }
        return value
    }

    private func prefillForEditing() {
        if let liability = editingLiability {
            name = liability.name
            category = liability.category
            balanceText = Self.formatAmountForInput(liability.currentBalance, decimals: liability.currencyCode.decimals)
            if let original = liability.originalAmount {
                originalText = Self.formatAmountForInput(original, decimals: liability.currencyCode.decimals)
            }
            if let rate = liability.interestRate {
                interestRateText = String(format: "%.3f", rate)
                    .replacingOccurrences(of: ",", with: ".")
            }
            currency = liability.currencyCode
            if let monthly = liability.monthlyPayment {
                monthlyPaymentText = Self.formatAmountForInput(monthly, decimals: liability.currencyCode.decimals)
            }
            notes = liability.notes ?? ""
            if let dateStr = liability.endDate,
               let date = NetWorthSnapshotRepository.dateFormatter.date(from: dateStr) {
                hasEndDate = true
                endDate = date
            }
        } else {
            if let initial = initialCategory {
                category = initial
            }
            currency = appViewModel.currencyManager.dataCurrency
        }
    }

    private static func formatAmountForInput(_ kopecks: Int64, decimals: Int) -> String {
        let decimal = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = ""
        f.decimalSeparator = "."
        return f.string(from: decimal as NSDecimalNumber) ?? ""
    }
}
