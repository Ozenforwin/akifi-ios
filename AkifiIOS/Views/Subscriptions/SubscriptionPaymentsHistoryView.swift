import SwiftUI

/// Lists all recorded payments for a subscription and lets the user add a new one.
///
/// Adding a payment is an atomic-ish operation handled by `SubscriptionsViewModel.recordPayment`:
/// - inserts a row into `subscription_payments`,
/// - updates `last_payment_date` on the subscription,
/// - recalculates `next_payment_date`,
/// - reschedules the local reminder.
struct SubscriptionPaymentsHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionTracker
    /// Invoked after changes (add/delete) so the parent can refresh its cache.
    let onChange: () async -> Void

    @State private var payments: [SubscriptionPayment] = []
    @State private var isLoading = false
    @State private var showAdd = false
    @State private var errorMessage: String?

    @State private var viewModel = SubscriptionsViewModel()
    private let repo = SubscriptionTrackerRepository()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && payments.isEmpty {
                    LoadingView()
                } else if payments.isEmpty {
                    ContentUnavailableView(
                        String(localized: "subscriptions.noPayments"),
                        systemImage: "list.bullet.rectangle",
                        description: Text(String(localized: "subscriptions.noPaymentsDescription"))
                    )
                } else {
                    List {
                        ForEach(payments) { payment in
                            paymentRow(payment)
                        }
                        .onDelete(perform: deletePayments)
                    }
                }
            }
            .navigationTitle(String(localized: "subscriptions.paymentHistory"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                AddPaymentForm(subscription: subscription) { amount, date in
                    // Seed VM with the current subscription for recordPayment to work.
                    viewModel.subscriptions = [subscription]
                    _ = await viewModel.recordPayment(subscriptionId: subscription.id, amount: amount, date: date)
                    await load()
                    await onChange()
                }
                .presentationBackground(.ultraThinMaterial)
            }
            .alert(
                String(localized: "common.error"),
                isPresented: .constant(errorMessage != nil),
                presenting: errorMessage
            ) { _ in
                Button(String(localized: "common.ok")) { errorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: - Rows

    private func paymentRow(_ payment: SubscriptionPayment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDate(payment.paymentDate))
                    .font(.subheadline.weight(.medium))
                if let createdAt = payment.createdAt {
                    Text(formatDate(createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(formatAmount(payment.amount, currency: payment.currency))
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        do {
            payments = try await repo.fetchPayments(for: subscription.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deletePayments(at offsets: IndexSet) {
        Task {
            for idx in offsets {
                let payment = payments[idx]
                do {
                    try await repo.deletePayment(id: payment.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            await load()
            await onChange()
        }
    }

    // MARK: - Formatting

    private func formatDate(_ raw: String) -> String {
        guard let date = SubscriptionDateEngine.parseDbDate(raw) else { return raw }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }

    private func formatAmount(_ amountCents: Int64, currency: String) -> String {
        let amount = Double(amountCents) / 100.0
        let cur = currency.uppercased()
        let symbol: String = switch cur {
        case "USD": "$"; case "EUR": "€"; case "RUB": "₽"
        case "VND": "₫"; case "THB": "฿"; case "IDR": "Rp"
        default: cur
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = (cur == "RUB" || cur == "VND" || cur == "THB" || cur == "IDR") ? 0 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        let formatted = formatter.string(from: NSNumber(value: amount)) ?? "0"
        return "\(formatted) \(symbol)"
    }
}

// MARK: - Add payment form

private struct AddPaymentForm: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionTracker
    /// Callback: (amountCents, paymentDate)
    let onSave: (Int64, Date) async -> Void

    @State private var amountText: String = ""
    @State private var paymentDate: Date = Date()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        String(localized: "subscriptions.paymentDate"),
                        selection: $paymentDate,
                        displayedComponents: .date
                    )
                    TextField(String(localized: "common.amount"), text: $amountText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(String(localized: "subscriptions.addPayment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save")) {
                        Task { await save() }
                    }
                    .disabled(amountText.isEmpty || isSaving)
                }
            }
            .onAppear {
                // Default to subscription's amount (in rubles).
                amountText = "\(subscription.amount.displayAmount)"
            }
        }
    }

    private func save() async {
        isSaving = true
        guard let decimal = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) else { return }
        let amountCents = Int64(truncating: (decimal * 100) as NSDecimalNumber)
        await onSave(amountCents, paymentDate)
        dismiss()
    }
}
