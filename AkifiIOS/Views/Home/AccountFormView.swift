import SwiftUI

struct AccountFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let editingAccount: Account?
    let onSave: () async -> Void

    @State private var name = ""
    @State private var selectedIcon = "💳"
    @State private var selectedColor = "#4ADE80"
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
                Section("Название") {
                    TextField("Мой счёт", text: $name)
                }

                Section(String(localized: "account.balance")) {
                    HStack {
                        TextField("0", text: $initialBalanceText)
                            .keyboardType(.decimalPad)
                        Text(appViewModel.currencyManager.selectedCurrency.symbol)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Валюта") {
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

                Section("Иконка") {
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

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Редактировать счёт" : "Новый счёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Сохранить" : "Создать") {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .onAppear { prefill() }
        }
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

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        selectedIcon = account.icon
        selectedColor = account.color
        selectedCurrency = account.currencyCode
        // Show current total balance (initial + net) converted to display currency
        // This is exactly what the user sees on the card
        let totalKopecks = appViewModel.dataStore.balance(for: account)
        let totalInBase = totalKopecks.displayAmount  // kopecks → base currency units
        let converted = appViewModel.currencyManager.convert(totalInBase)
        let rounded = NSDecimalNumber(decimal: converted * 100).rounding(accordingToBehavior: nil)
        let final = Decimal(string: rounded.stringValue)! / 100
        initialBalanceText = "\(final)"
    }

    private func save() async {
        isSaving = true
        do {
            if let account = editingAccount {
                // User entered desired balance in display currency
                // Convert back to base (RUB), subtract net to get new initial_balance
                let newBalance: Int64?
                if let desired = Decimal(string: initialBalanceText.replacingOccurrences(of: ",", with: ".")) {
                    let desiredInBase = appViewModel.currencyManager.toBase(desired)
                    let desiredKopecks = Int64(truncating: (desiredInBase * 100) as NSDecimalNumber)
                    let net = accountNet(for: account)
                    let newInitial = desiredKopecks - net
                    newBalance = newInitial != account.initialBalance ? newInitial : nil
                } else {
                    newBalance = nil
                }
                try await accountRepo.update(id: account.id, name: name, icon: selectedIcon, color: selectedColor, currency: selectedCurrency.rawValue.lowercased(), initialBalance: newBalance)
            } else {
                let balance: Int64
                if let decimal = Decimal(string: initialBalanceText.replacingOccurrences(of: ",", with: ".")) {
                    balance = Int64(truncating: (decimal * 100) as NSDecimalNumber)
                } else {
                    balance = 0
                }
                _ = try await accountRepo.create(name: name, icon: selectedIcon, color: selectedColor, initialBalance: balance, currency: selectedCurrency.rawValue.lowercased())
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
