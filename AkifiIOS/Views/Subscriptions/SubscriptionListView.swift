import SwiftUI

struct SubscriptionListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = SubscriptionsViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.subscriptions.isEmpty {
                LoadingView()
            } else if viewModel.subscriptions.isEmpty {
                EmptyStateView(
                    title: String(localized: "subscriptions.empty"),
                    systemImage: "repeat.circle",
                    description: String(localized: "subscriptions.emptyDescription"),
                    actionTitle: String(localized: "common.add")
                ) {
                    viewModel.showForm = true
                }
            } else {
                List {
                    Section {
                        HStack {
                            Text(String(localized: "subscriptions.perMonth"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(appViewModel.currencyManager.formatAmount(viewModel.monthlyTotal.displayAmount))
                                .font(.headline)
                        }
                    }

                    if !viewModel.activeSubscriptions.isEmpty {
                        Section(String(localized: "subscriptions.section.active")) {
                            ForEach(viewModel.activeSubscriptions) { sub in
                                SubscriptionRowView(subscription: sub)
                            }
                            .onDelete { indices in
                                Task {
                                    for index in indices {
                                        await viewModel.delete(viewModel.activeSubscriptions[index])
                                    }
                                }
                            }
                        }
                    }

                    if !viewModel.pausedSubscriptions.isEmpty {
                        Section(String(localized: "subscriptions.section.paused")) {
                            ForEach(viewModel.pausedSubscriptions) { sub in
                                SubscriptionRowView(subscription: sub)
                            }
                        }
                    }

                    if !viewModel.archivedSubscriptions.isEmpty {
                        Section(String(localized: "subscriptions.section.archive")) {
                            ForEach(viewModel.archivedSubscriptions) { sub in
                                SubscriptionRowView(subscription: sub)
                                    .opacity(0.55)
                            }
                        }
                    }

                    Color.clear.frame(height: 100)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .navigationTitle(String(localized: "subscriptions.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showForm = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.showForm) {
            SubscriptionFormView { name, amount, period, color, currency, reminderDays, lastDate, nextDate, categoryId in
                await viewModel.create(
                    name: name, amount: amount, period: period, color: color,
                    currency: currency, reminderDays: reminderDays,
                    lastPaymentDate: lastDate, nextPaymentDate: nextDate,
                    categoryId: categoryId
                )
            }
            .presentationBackground(.ultraThinMaterial)
        }
    }
}

struct SubscriptionRowView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let subscription: SubscriptionTracker

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: subscription.iconColor ?? "#60A5FA"))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(String(subscription.serviceName.prefix(1)).uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(subscription.serviceName)
                        .font(.subheadline.weight(.medium))
                    if subscription.status != .active {
                        Image(systemName: subscription.status.systemImage)
                            .font(.caption2)
                            .foregroundStyle(subscription.status == .paused ? Color.warning : .secondary)
                    }
                }
                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(appViewModel.currencyManager.formatAmount(subscription.amount.displayAmount))
                .font(.subheadline.weight(.semibold))
        }
    }

    private var periodLabel: String {
        switch subscription.billingPeriod {
        case .weekly: String(localized: "subscription.period.weekly")
        case .monthly: String(localized: "subscription.period.monthly")
        case .quarterly: String(localized: "subscription.period.quarterly")
        case .yearly: String(localized: "subscription.period.yearly")
        case .custom: String(localized: "subscription.period.custom")
        }
    }
}

// MARK: - Create Form

struct SubscriptionFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    /// Callback: (name, amountCents, period, color, currency, reminderDays, lastPayment?, nextPayment, categoryId?)
    let onSave: (String, Int64, BillingPeriod, String?, String, Int, Date?, Date, String?) async -> Void

    @State private var name = ""
    @State private var amountText = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var selectedColor = "#60A5FA"
    @State private var reminderDays: Int = 1
    @State private var selectedCategoryId: String?
    @State private var isSaving = false

    @State private var specifyLastPayment = false
    @State private var lastPaymentDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var nextPaymentDate: Date = SubscriptionDateEngine.nextPaymentDate(
        from: Calendar.current.startOfDay(for: Date()), period: .monthly
    )
    @State private var nextManuallyEdited = false

    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]

    private var expenseCategories: [Category] {
        appViewModel.dataStore.categories.filter { $0.type == .expense }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "subscriptions.subscription")) {
                    TextField(String(localized: "subscriptions.serviceName"), text: $name)
                    TextField(String(localized: "transfer.amount"), text: $amountText)
                        .keyboardType(.decimalPad)

                    Picker(String(localized: "subscriptions.period"), selection: $period) {
                        Text(String(localized: "billingPeriod.weekly")).tag(BillingPeriod.weekly)
                        Text(String(localized: "billingPeriod.monthly")).tag(BillingPeriod.monthly)
                        Text(String(localized: "billingPeriod.quarterly")).tag(BillingPeriod.quarterly)
                        Text(String(localized: "billingPeriod.yearly")).tag(BillingPeriod.yearly)
                    }
                    .onChange(of: period) { _, newValue in
                        if !nextManuallyEdited {
                            let base = specifyLastPayment ? lastPaymentDate : Calendar.current.startOfDay(for: Date())
                            nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(from: base, period: newValue)
                        }
                    }

                    Picker(String(localized: "common.currency"), selection: $selectedCurrency) {
                        ForEach(CurrencyCode.allCases, id: \.self) { currency in
                            Text("\(currency.symbol) \(currency.name)").tag(currency)
                        }
                    }

                    Picker(String(localized: "subscriptions.category"), selection: $selectedCategoryId) {
                        Text(String(localized: "subscriptions.noCategory")).tag(String?.none)
                        ForEach(expenseCategories, id: \.id) { cat in
                            Text("\(cat.icon) \(cat.name)").tag(String?(cat.id))
                        }
                    }
                }

                Section {
                    Toggle(String(localized: "subscriptions.specifyLastPayment"), isOn: $specifyLastPayment)
                    if specifyLastPayment {
                        DatePicker(
                            String(localized: "subscriptions.lastPayment"),
                            selection: $lastPaymentDate,
                            displayedComponents: .date
                        )
                        .onChange(of: lastPaymentDate) { _, newValue in
                            if !nextManuallyEdited {
                                nextPaymentDate = SubscriptionDateEngine.nextPaymentDate(from: newValue, period: period)
                            }
                        }
                    }
                    DatePicker(
                        String(localized: "subscriptions.nextPayment"),
                        selection: $nextPaymentDate,
                        displayedComponents: .date
                    )
                    .onChange(of: nextPaymentDate) { _, _ in
                        nextManuallyEdited = true
                    }
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
        }
    }

    private func save() async {
        isSaving = true
        guard let decimal = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        let last: Date? = specifyLastPayment ? lastPaymentDate : nil
        await onSave(
            name, amountCents, period, selectedColor, selectedCurrency.rawValue,
            reminderDays, last, nextPaymentDate, selectedCategoryId
        )
        dismiss()
    }
}
