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

                Section(isEditing ? "Баланс (\(selectedCurrency.symbol))" : "Начальный баланс (\(selectedCurrency.symbol))") {
                    TextField("0", text: $initialBalanceText)
                        .keyboardType(.decimalPad)
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

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        selectedIcon = account.icon
        selectedColor = account.color
        selectedCurrency = account.currencyCode
        // Show initial_balance from DB in account's own currency (no conversion)
        // DB stores whole units, model multiplies by 100 for internal kopecks
        let dbUnits = account.initialBalance / 100  // back to DB units
        initialBalanceText = "\(dbUnits)"
    }

    private func save() async {
        isSaving = true
        do {
            if let account = editingAccount {
                // User enters initial_balance in account's currency (whole units)
                // DB stores whole units, we send as kopecks to repo (which divides by 100)
                let newBalance: Int64?
                if let decimal = Decimal(string: initialBalanceText.replacingOccurrences(of: ",", with: ".")) {
                    let kopecks = Int64(truncating: (decimal * 100) as NSDecimalNumber)
                    newBalance = kopecks != account.initialBalance ? kopecks : nil
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
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
