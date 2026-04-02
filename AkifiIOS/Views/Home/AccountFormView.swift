import SwiftUI

struct AccountFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let editingAccount: Account?
    let onSave: () async -> Void

    @State private var name = ""
    @State private var selectedIcon = "💳"
    @State private var selectedColor = "#A78BFA"
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var initialBalanceText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let accountRepo = AccountRepository()

    private let icons = ["💳", "🏦", "💰", "👛", "💵", "🪙", "💎", "🏠", "🚗", "✈️", "🎓", "📱"]
    private let colors = ["#4ADE80", "#60A5FA", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399", "#38BDF8", "#C084FC"]

    private var isEditing: Bool { editingAccount != nil }

    init(editingAccount: Account? = nil, onSave: @escaping () async -> Void) {
        self.editingAccount = editingAccount
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "common.name")) {
                    TextField(String(localized: "account.namePlaceholder"), text: $name)
                }

                Section(String(localized: "account.balance")) {
                    HStack {
                        TextField("0", text: $initialBalanceText)
                            .keyboardType(.decimalPad)
                        Text(selectedCurrency.symbol)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "settings.currency")) {
                    ForEach(CurrencyCode.allCases, id: \.self) { currency in
                        Button {
                            selectedCurrency = currency
                        } label: {
                            HStack {
                                Text(currency.symbol)
                                    .font(.title3)
                                    .frame(width: 30)
                                Text(currency.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedCurrency == currency {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accent)
                                }
                            }
                        }
                    }
                }

                Section(String(localized: "categories.icon")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Text(icon)
                                .font(.title)
                                .frame(width: 48, height: 48)
                                .background(selectedIcon == icon ? Color(hex: selectedColor).opacity(0.3) : .clear)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(selectedIcon == icon ? Color(hex: selectedColor) : .clear, lineWidth: 2) }
                                .onTapGesture { selectedIcon = icon }
                        }
                    }
                }

                Section(String(localized: "categories.color")) {
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

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "account.edit") : String(localized: "account.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "common.save") : String(localized: "common.create")) {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .onAppear { prefill() }
        }
    }

    // MARK: - Helpers

    /// Rate for converting between account currency and base (data) currency
    private func rateForCurrency(_ currency: CurrencyCode) -> Double {
        let cm = appViewModel.currencyManager
        let baseRate = cm.rates[cm.dataCurrency.rawValue] ?? 1.0
        let targetRate = cm.rates[currency.rawValue] ?? 1.0
        guard baseRate > 0 else { return 1.0 }
        return targetRate / baseRate
    }

    /// Convert base currency amount (RUB) to account currency using Double
    private func baseToAccount(_ rubles: Double, currency: CurrencyCode) -> Double {
        rubles * rateForCurrency(currency)
    }

    /// Convert account currency amount to base currency (RUB) using Double
    private func accountToBase(_ amount: Double, currency: CurrencyCode) -> Double {
        let rate = rateForCurrency(currency)
        guard rate > 0 else { return amount }
        return amount / rate
    }

    /// Net transaction amount for account (income - expense) in kopecks
    private func accountNet(for account: Account) -> Int64 {
        var net: Int64 = 0
        for tx in appViewModel.dataStore.transactions {
            guard tx.accountId == account.id else { continue }
            if tx.type == .income { net += tx.amount }
            else if tx.type == .expense { net -= tx.amount }
        }
        return net
    }

    // MARK: - Prefill

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        selectedIcon = account.icon
        selectedColor = account.color
        selectedCurrency = account.currencyCode

        // Current total balance in kopecks (initial + net)
        let totalKopecks = appViewModel.dataStore.balance(for: account)
        // Convert kopecks → rubles (Double) → account currency
        let totalRubles = Double(totalKopecks) / 100.0
        let inAccountCurrency = baseToAccount(totalRubles, currency: account.currencyCode)
        // Round to 2 decimals
        let rounded = (inAccountCurrency * 100).rounded() / 100
        initialBalanceText = rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.2f", rounded)
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        do {
            let parsed = Double(initialBalanceText.replacingOccurrences(of: ",", with: ".")) ?? 0

            if let account = editingAccount {
                // User entered desired total balance in account's currency
                // Convert to base (RUB), then to kopecks
                let desiredRubles = accountToBase(parsed, currency: selectedCurrency)
                let desiredKopecks = Int64((desiredRubles * 100).rounded())
                // Subtract net transactions to get new initial_balance
                let net = accountNet(for: account)
                let newInitial = desiredKopecks - net
                let newBalance: Int64? = newInitial != account.initialBalance ? newInitial : nil
                try await accountRepo.update(id: account.id, name: name, icon: selectedIcon, color: selectedColor, currency: selectedCurrency.rawValue.lowercased(), initialBalance: newBalance)
            } else {
                // New account: entered balance IS the initial balance in account currency
                // Convert to base (RUB) kopecks
                let rubles = accountToBase(parsed, currency: selectedCurrency)
                let kopecks = Int64((rubles * 100).rounded())
                _ = try await accountRepo.create(name: name, icon: selectedIcon, color: selectedColor, initialBalance: kopecks, currency: selectedCurrency.rawValue.lowercased())
                AnalyticsService.logCreateAccount()
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
