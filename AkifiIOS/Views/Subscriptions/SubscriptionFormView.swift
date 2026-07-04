import SwiftUI

struct SubscriptionFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    /// Callback: (name, amountCents, period, color, currency, reminderDays, lastPayment?, nextPayment, categoryId?, accountId?)
    /// Returns nil on success, or a user-facing error message — the form
    /// stays open and shows it, instead of silently dismissing a failed save.
    let onSave: (String, Int64, BillingPeriod, String?, String, Int, Date?, Date, String?, String?) async -> String?

    @State private var name = ""
    @State private var amountText = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var selectedColor = "#60A5FA"
    @State private var reminderDays: Int = 1
    @State private var selectedCategoryId: String?
    @State private var selectedAccountId: String?
    @State private var isSaving = false

    @State private var specifyLastPayment = false
    @State private var lastPaymentDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var nextPaymentDate: Date = SubscriptionDateEngine.nextPaymentDate(
        from: Calendar.current.startOfDay(for: Date()), period: .monthly
    )
    @State private var nextManuallyEdited = false
    @State private var errorMessage: String?

    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]

    private var expenseCategories: [Category] {
        appViewModel.dataStore.displayCategories.filter { $0.type == .expense }
    }

    private var accounts: [Account] {
        appViewModel.dataStore.accounts
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "subscriptions.subscription")) {
                    TextField(String(localized: "subscriptions.serviceName"), text: $name)
                    TextField(String(localized: "transfer.amount"), text: $amountText)
                        .keyboardType(.decimalPad)

                    // User-action bindings, NOT .onChange: onChange also fires
                    // on programmatic assignments (prefill/recalc), which used
                    // to permanently latch nextManuallyEdited and freeze the
                    // auto-recalc of the next payment date.
                    Picker(String(localized: "subscriptions.period"), selection: Binding(
                        get: { period },
                        set: { period = $0; recalcNextIfAuto() }
                    )) {
                        Text(String(localized: "billingPeriod.weekly")).tag(BillingPeriod.weekly)
                        Text(String(localized: "billingPeriod.monthly")).tag(BillingPeriod.monthly)
                        Text(String(localized: "billingPeriod.quarterly")).tag(BillingPeriod.quarterly)
                        Text(String(localized: "billingPeriod.yearly")).tag(BillingPeriod.yearly)
                    }

                    HStack {
                        Text(String(localized: "common.currency"))
                            .foregroundStyle(.primary)
                        Spacer()
                        ActiveCurrencyPicker(selection: $selectedCurrency)
                    }
                    .frame(minHeight: 44)

                    Picker(String(localized: "subscriptions.category"), selection: $selectedCategoryId) {
                        Text(String(localized: "subscriptions.noCategory")).tag(String?.none)
                        ForEach(expenseCategories, id: \.id) { cat in
                            Text("\(cat.icon) \(cat.name)").tag(String?(cat.id))
                        }
                    }

                    Picker(String(localized: "subscription.account"), selection: $selectedAccountId) {
                        Text(String(localized: "subscription.account.none")).tag(String?.none)
                        ForEach(accounts, id: \.id) { account in
                            Text("\(account.icon) \(account.name)").tag(String?(account.id))
                        }
                    }
                }

                Section {
                    Toggle(String(localized: "subscriptions.specifyLastPayment"), isOn: Binding(
                        get: { specifyLastPayment },
                        set: { specifyLastPayment = $0; recalcNextIfAuto() }
                    ))
                    if specifyLastPayment {
                        DatePicker(
                            String(localized: "subscriptions.lastPayment"),
                            selection: Binding(
                                get: { lastPaymentDate },
                                set: { lastPaymentDate = $0; recalcNextIfAuto() }
                            ),
                            displayedComponents: .date
                        )
                    }
                    DatePicker(
                        String(localized: "subscriptions.nextPayment"),
                        selection: Binding(
                            get: { nextPaymentDate },
                            set: { nextPaymentDate = $0; nextManuallyEdited = true }
                        ),
                        displayedComponents: .date
                    )
                } header: {
                    Text(String(localized: "subscriptions.datesSection"))
                } footer: {
                    Text(String(localized: "subscriptions.autoCalculated"))
                }

                Section(String(localized: "subscriptions.reminder")) {
                    Picker(String(localized: "subscriptions.remind"), selection: $reminderDays) {
                        Text(String(localized: "subscriptions.onChargeDay")).tag(0)
                        Text(String(localized: "subscriptions.daysBefore.1")).tag(1)
                        Text(String(localized: "subscriptions.daysBefore.2")).tag(2)
                        Text(String(localized: "subscriptions.daysBefore.3")).tag(3)
                        Text(String(localized: "subscriptions.daysBefore.5")).tag(5)
                        Text(String(localized: "subscriptions.daysBefore.7")).tag(7)
                        Text(String(localized: "subscriptions.daysBefore.14")).tag(14)
                        Text(String(localized: "subscriptions.daysBefore.30")).tag(30)
                    }
                }

                Section(String(localized: "categories.color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
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
            }
            .navigationTitle(String(localized: "subscriptions.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.add")) {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || amountText.isEmpty || isSaving)
                }
            }
            .alert(
                String(localized: "common.error"),
                isPresented: .init(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(String(localized: "common.ok")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Recomputes the next payment date from the last-payment anchor (or
    /// today) unless the user has explicitly overridden it by touching the
    /// next-payment picker.
    private func recalcNextIfAuto() {
        guard !nextManuallyEdited else { return }
        let base = specifyLastPayment ? lastPaymentDate : Calendar.current.startOfDay(for: Date())
        nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(from: base, period: period)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard let decimal = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        let last: Date? = specifyLastPayment ? lastPaymentDate : nil
        let error = await onSave(
            name, amountCents, period, selectedColor, selectedCurrency.code,
            reminderDays, last, nextPaymentDate, selectedCategoryId, selectedAccountId
        )
        if let error {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
