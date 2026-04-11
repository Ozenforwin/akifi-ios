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

                    Section(String(localized: "subscriptions.active")) {
                        ForEach(viewModel.subscriptions) { sub in
                            SubscriptionRowView(subscription: sub)
                        }
                        .onDelete { indices in
                            Task {
                                for index in indices {
                                    await viewModel.delete(viewModel.subscriptions[index])
                                }
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
            SubscriptionFormView { name, amount, period, color, currency, reminderDays in
                if let uid = appViewModel.dataStore.profile?.id {
                    await viewModel.create(name: name, amount: amount, period: period, color: color, currency: currency, reminderDays: reminderDays, userId: uid)
                }
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
                Text(subscription.serviceName)
                    .font(.subheadline.weight(.medium))
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

struct SubscriptionFormView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, Int64, BillingPeriod, String?, String, Int) async -> Void

    @State private var name = ""
    @State private var amountText = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedCurrency: CurrencyCode = .rub
    @State private var selectedColor = "#60A5FA"
    @State private var reminderDays: Int = 1
    @State private var isSaving = false

    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "subscriptions.subscription")) {
                    TextField(String(localized: "subscriptions.serviceName"), text: $name)
                    TextField(String(localized: "transfer.amount"), text: $amountText)
                        .keyboardType(.decimalPad)

                    Picker(String(localized: "subscriptions.period"), selection: $period) {
                        Text(String(localized: "billingPeriod.monthly")).tag(BillingPeriod.monthly)
                        Text(String(localized: "billingPeriod.quarterly")).tag(BillingPeriod.quarterly)
                        Text(String(localized: "billingPeriod.yearly")).tag(BillingPeriod.yearly)
                    }
                    Picker(String(localized: "common.currency"), selection: $selectedCurrency) {
                        ForEach(CurrencyCode.allCases, id: \.self) { currency in
                            Text("\(currency.symbol) \(currency.name)").tag(currency)
                        }
                    }
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
        await onSave(name, amountCents, period, selectedColor, selectedCurrency.rawValue, reminderDays)
        dismiss()
    }
}
