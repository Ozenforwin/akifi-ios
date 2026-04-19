import SwiftUI

/// Phase 4 of ADR-001 — lets the user audit legacy transactions where the
/// stored `currency` label does not match the owning account's currency.
///
/// The Phase 1 backfill left these rows with `amount_native = amount`,
/// which is the safest interpretation ("the number is already in the
/// account's currency"). For users coming from the Telegram Mini App that
/// assumption is often wrong — the label was a display tag, not the unit
/// the number was stored in. This screen surfaces each suspicious row and
/// lets the user pick the correct interpretation, which then rewrites
/// `amount_native` + `foreign_*` accordingly.
///
/// The screen is the ONLY path in the app that can mutate `amount_native`
/// on a legacy row without re-entering the transaction from scratch.
struct CurrencyReconciliationView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var suspiciousRows: [SuspiciousRow] {
        let accounts = Dictionary(
            uniqueKeysWithValues: appViewModel.dataStore.accounts.map { ($0.id, $0) }
        )
        return appViewModel.dataStore.transactions.compactMap { tx in
            guard let accId = tx.accountId,
                  let account = accounts[accId],
                  let label = tx.currency, !label.isEmpty,
                  tx.foreignCurrency == nil,
                  label.lowercased() != account.currency.lowercased()
            else { return nil }
            return SuspiciousRow(transaction: tx, account: account)
        }
        .sorted { $0.transaction.rawDateTime > $1.transaction.rawDateTime }
    }

    var body: some View {
        NavigationStack {
            List {
                if suspiciousRows.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.green)
                            Text(String(localized: "currencyReconciliation.empty.title"))
                                .font(.headline)
                            Text(String(localized: "currencyReconciliation.empty.subtitle"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        Text(String(localized: "currencyReconciliation.intro"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(suspiciousRows) { row in
                        ReconciliationRow(row: row) { decision in
                            await applyDecision(row: row, decision: decision)
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
            .navigationTitle(String(localized: "currencyReconciliation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done")) { dismiss() }
                }
            }
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    private func applyDecision(row: SuspiciousRow, decision: ReconciliationDecision) async {
        isLoading = true
        defer { isLoading = false }

        do {
            switch decision {
            case .keepAsAccountCurrency:
                // The stored number was already correct — just clear the
                // misleading label so the row stops surfacing here.
                try await appViewModel.dataStore.updateTransaction(
                    id: row.transaction.id,
                    UpdateTransactionInput(currency: row.account.currency.uppercased())
                )
            case .reinterpretAsLabel:
                // The stored number was in `label` currency, not the
                // account's. Convert to account currency and record foreign_*.
                let cm = appViewModel.currencyManager
                let labelCode = CurrencyCode(rawValue: row.transaction.currency?.uppercased() ?? "") ?? .rub
                let accountCode = row.account.currencyCode
                let originalAmount = row.transaction.amountNative.displayAmount
                let converted = convert(
                    amount: originalAmount,
                    from: labelCode,
                    to: accountCode,
                    using: cm
                )
                let fx: Decimal? = originalAmount != 0
                    ? converted / originalAmount
                    : nil
                try await appViewModel.dataStore.updateTransaction(
                    id: row.transaction.id,
                    UpdateTransactionInput(
                        amount: converted,
                        amount_native: converted,
                        currency: accountCode.rawValue.uppercased(),
                        foreign_amount: originalAmount,
                        foreign_currency: labelCode.rawValue.uppercased(),
                        fx_rate: fx
                    )
                )
            case .delete:
                await appViewModel.dataStore.deleteTransaction(row.transaction)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func convert(amount: Decimal, from: CurrencyCode, to: CurrencyCode, using cm: CurrencyManager) -> Decimal {
        guard from != to else { return amount }
        let fromRate = Decimal(cm.rates[from.rawValue] ?? 1.0)
        let toRate = Decimal(cm.rates[to.rawValue] ?? 1.0)
        guard fromRate != 0 else { return amount }
        return amount / fromRate * toRate
    }
}

private struct SuspiciousRow: Identifiable {
    let transaction: Transaction
    let account: Account
    var id: String { transaction.id }
}

private enum ReconciliationDecision {
    case keepAsAccountCurrency
    case reinterpretAsLabel
    case delete
}

private struct ReconciliationRow: View {
    let row: SuspiciousRow
    let onDecision: (ReconciliationDecision) async -> Void

    @Environment(AppViewModel.self) private var appViewModel
    @State private var isActing = false

    private var labelCode: CurrencyCode? {
        guard let raw = row.transaction.currency else { return nil }
        return CurrencyCode(rawValue: raw.uppercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.transaction.description ?? String(localized: "transaction.untitled"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(row.account.icon) \(row.account.name)  ·  \(row.transaction.date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                keepOption
                reinterpretOption
            }

            Button(role: .destructive) {
                Task {
                    isActing = true
                    await onDecision(.delete)
                    isActing = false
                }
            } label: {
                Label(String(localized: "currencyReconciliation.delete"), systemImage: "trash")
                    .font(.caption)
            }
            .disabled(isActing)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var keepOption: some View {
        let amount = row.transaction.amountNative.displayAmount
        Button {
            Task {
                isActing = true
                await onDecision(.keepAsAccountCurrency)
                isActing = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "currencyReconciliation.keep.title"))
                    .font(.caption.weight(.semibold))
                Text(TransactionFormView.formatRawAmount(amount, currency: row.account.currencyCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isActing)
    }

    @ViewBuilder
    private var reinterpretOption: some View {
        let cm = appViewModel.currencyManager
        let amount = row.transaction.amountNative.displayAmount
        let accountCode = row.account.currencyCode
        if let labelCode {
            let fromRate = Decimal(cm.rates[labelCode.rawValue] ?? 1.0)
            let toRate = Decimal(cm.rates[accountCode.rawValue] ?? 1.0)
            let converted: Decimal = {
                guard fromRate != 0 else { return amount }
                return amount / fromRate * toRate
            }()

            Button {
                Task {
                    isActing = true
                    await onDecision(.reinterpretAsLabel)
                    isActing = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "currencyReconciliation.reinterpret.title"))
                        .font(.caption.weight(.semibold))
                    Text(TransactionFormView.formatRawAmount(amount, currency: labelCode))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("≈ \(TransactionFormView.formatRawAmount(converted, currency: accountCode))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(isActing)
        }
    }
}
