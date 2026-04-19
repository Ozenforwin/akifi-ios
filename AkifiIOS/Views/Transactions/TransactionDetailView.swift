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
        return "\(sign)\(cm.formatAmount(transaction.amount.displayAmount))"
    }

    private var amountColor: Color {
        switch transaction.type {
        case .income:   return .income
        case .expense:  return .expense
        case .transfer: return .transfer
        }
    }
}
