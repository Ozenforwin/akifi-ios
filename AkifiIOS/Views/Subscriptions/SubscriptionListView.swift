import SwiftUI

struct SubscriptionListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = SubscriptionsViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.subscriptions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.subscriptions.isEmpty {
                ContentUnavailableView(
                    "Нет подписок",
                    systemImage: "repeat.circle",
                    description: Text("Добавьте подписки для отслеживания")
                )
            } else {
                List {
                    Section {
                        HStack {
                            Text("В месяц")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(appViewModel.currencyManager.formatAmount(viewModel.monthlyTotal.displayAmount))
                                .font(.headline)
                        }
                    }

                    Section("Активные") {
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
                }
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .navigationTitle("Подписки")
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
            SubscriptionFormView { name, amount, period, color in
                await viewModel.create(name: name, amount: amount, period: period, color: color)
            }
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
        case .monthly: "Ежемесячно"
        case .quarterly: "Ежеквартально"
        case .yearly: "Ежегодно"
        }
    }
}

struct SubscriptionFormView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, Int64, BillingPeriod, String?) async -> Void

    @State private var name = ""
    @State private var amountText = ""
    @State private var period: BillingPeriod = .monthly
    @State private var selectedColor = "#60A5FA"
    @State private var isSaving = false

    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Подписка") {
                    TextField("Название сервиса", text: $name)
                    TextField("Сумма", text: $amountText)
                        .keyboardType(.decimalPad)

                    Picker("Период", selection: $period) {
                        Text("Месяц").tag(BillingPeriod.monthly)
                        Text("Квартал").tag(BillingPeriod.quarterly)
                        Text("Год").tag(BillingPeriod.yearly)
                    }
                }

                Section("Цвет") {
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
            .navigationTitle("Новая подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || amountText.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        guard let decimal = Decimal(string: amountText) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        await onSave(name, amountCents, period, selectedColor)
        dismiss()
    }
}
