import SwiftUI

/// Read-only detail screen for a single transaction. Surfaces:
/// - Amount + category
/// - "From {source account}" badge for auto-transferred expenses
/// - Edit / Delete buttons (Delete blocks on transfer-legs with a warning)
struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    let transaction: Transaction
    var onEdit: (() -> Void)?

    @State private var showTransferLegDeleteWarning = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?

    private var dataStore: DataStore { appViewModel.dataStore }

    private var category: Category? {
        guard let id = transaction.categoryId else { return nil }
        return dataStore.categories.first { $0.id == id }
    }

    private var account: Account? {
        guard let id = transaction.accountId else { return nil }
        return dataStore.accounts.first { $0.id == id }
    }

    private var paymentSource: Account? {
        guard let id = transaction.paymentSourceAccountId else { return nil }
        return dataStore.accounts.first { $0.id == id }
    }

    /// True iff this row is one of the two transfer-legs of an auto-transfer
    /// triplet. Direct deletion must be blocked — user has to delete the
    /// main expense instead.
    private var isAutoTransferLeg: Bool {
        transaction.autoTransferGroupId != nil && transaction.transferGroupId != nil
    }

    /// Main expense row for this auto-transfer group (looked up when the
    /// user hits Delete on a transfer-leg, to show the "linked to expense X" text).
    private var linkedExpense: Transaction? {
        guard let group = transaction.autoTransferGroupId else { return nil }
        return dataStore.transactions.first {
            $0.autoTransferGroupId == group && $0.transferGroupId == nil && $0.type == .expense
        }
    }

    var body: some View {
        NavigationStack {
            List {
                amountSection

                if let source = paymentSource, source.id != transaction.accountId {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "creditcard.fill")
                                .foregroundStyle(.blue)
                            Text(String(format: String(localized: "tx.autoTransfer.badge"), source.name))
                                .font(.subheadline)
                        }
                    }
                }

                detailsSection

                fireImpactSection

                Section {
                    Button {
                        onEdit?()
                        dismiss()
                    } label: {
                        Label(String(localized: "common.edit"), systemImage: "pencil")
                    }
                    .disabled(isAutoTransferLeg)

                    Button(role: .destructive) {
                        if isAutoTransferLeg {
                            showTransferLegDeleteWarning = true
                        } else {
                            showDeleteConfirm = true
                        }
                    } label: {
                        Label(String(localized: "common.delete"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(String(localized: "transaction.details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .alert(
                String(localized: "tx.autoTransfer.deleteWarning.title"),
                isPresented: $showTransferLegDeleteWarning
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                let desc = linkedExpense?.description ?? String(localized: "transaction.transfer")
                Text(String(format: String(localized: "tx.autoTransfer.deleteWarning.body"), desc))
            }
            .alert(
                String(localized: "transaction.deleteConfirm"),
                isPresented: $showDeleteConfirm
            ) {
                Button(String(localized: "common.cancel"), role: .cancel) {}
                Button(String(localized: "common.delete"), role: .destructive) {
                    Task {
                        await dataStore.deleteTransaction(transaction)
                        dismiss()
                    }
                }
            } message: {
                Text(String(localized: "transaction.deleteConfirmMessage"))
            }
            .alert(
                "Error",
                isPresented: .init(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
            ) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var amountSection: some View {
        Section {
            VStack(alignment: .center, spacing: 8) {
                Text(category?.icon ?? "📦")
                    .font(.system(size: 48))
                Text(formattedAmount)
                    .font(.title.weight(.bold))
                    .foregroundStyle(amountColor)
                    .monospacedDigit()
                if let cat = category {
                    Text(cat.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    /// Optional "FIRE impact" line — only shown when:
    /// * the row is an expense (income/transfers don't push FIRE back),
    /// * the user has at least 2 months of activity (savings-rate
    ///   confidence threshold),
    /// * the transaction is large enough to matter (> 5% of avg
    ///   monthly income — a $5 coffee delaying FIRE by 5 days is
    ///   anti-product),
    /// * the calculator returns a non-zero whole-month delay.
    private var fireImpactEstimate: FIREImpactCalculator.Estimate? {
        guard transaction.type == .expense, !isAutoTransferLeg else { return nil }
        let cm = appViewModel.currencyManager
        let baseCode = cm.dataCurrency.rawValue
        let accountsById = Dictionary(
            dataStore.accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let fxRates: [String: Decimal] = cm.rates.reduce(into: [:]) { acc, pair in
            acc[pair.key] = Decimal(pair.value)
        }
        let txAmount = TransactionMath.amountInBase(
            transaction, accountsById: accountsById, fxRates: fxRates, baseCode: baseCode
        )
        guard txAmount > 0 else { return nil }

        let rate = SavingsRateCalculator.compute(
            transactions: dataStore.transactions,
            subscriptions: dataStore.subscriptions,
            accountsById: accountsById,
            fxRates: fxRates,
            baseCode: baseCode
        )
        guard rate.sampleMonths >= 2, rate.avgMonthlyIncome > 0 else { return nil }
        // 5% threshold against avg monthly income.
        guard txAmount * 20 >= rate.avgMonthlyIncome else { return nil }

        // Approximate investable NW: account balances only. The
        // detail view doesn't have a NetWorthViewModel handy and
        // assets/liabilities require a fetch — accounts-only is a
        // close-enough proxy for the "delays FIRE by N months" line.
        var nw: Int64 = 0
        for acc in dataStore.accounts {
            nw += dataStore.balance(for: acc)
        }

        return FIREImpactCalculator.estimate(
            transactionAmount: txAmount,
            currentNetWorth: nw,
            monthlyContribution: max(rate.avgMonthlyNet, 0),
            monthlyExpenses: rate.avgMonthlyExpense + rate.monthlySubscriptionCost
        )
    }

    @ViewBuilder
    private var fireImpactSection: some View {
        if let est = fireImpactEstimate {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            LinearGradient(
                                colors: [Color.orange, Color.orange.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "tx.fireImpact.title"))
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: String(localized: "tx.fireImpact.bodyFormat"),
                                    est.monthsDelay))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } footer: {
                Text(String(localized: "tx.fireImpact.footer"))
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section(String(localized: "transaction.details")) {
            if let acc = account {
                row(label: String(localized: "common.account"), value: "\(acc.icon) \(acc.name)")
            }
            if let desc = transaction.description, !desc.isEmpty {
                row(label: String(localized: "transaction.description"), value: desc)
            }
            row(label: String(localized: "transaction.dateTime"), value: transaction.formattedDateTime)
            if let currency = transaction.currency {
                row(label: String(localized: "common.currency"), value: currency.uppercased())
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var formattedAmount: String {
        let cm = appViewModel.currencyManager
        let sign: String
        switch transaction.type {
        case .income: sign = "+"
        case .expense: sign = "-"
        case .transfer: sign = ""
        }
        return "\(sign)\(cm.formatAmount(appViewModel.dataStore.amountInBaseDisplay(transaction)))"
    }

    private var amountColor: Color {
        switch transaction.type {
        case .income:   return .income
        case .expense:  return .expense
        case .transfer: return .transfer
        }
    }
}
