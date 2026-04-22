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

    /// Cache of historical / pair-extracted FX rates keyed by transaction.id.
    /// Populated lazily in `.task` on mount. A `nil` value (vs. missing key)
    /// means "attempted but no quote available" — the row falls back to the
    /// current rate with a visible warning.
    @State private var resolvedRates: [String: ResolvedRate] = [:]

    private let exchangeService = ExchangeRateService()

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

    /// For each suspicious row, try to find a better-than-today FX rate.
    /// Priority:
    ///   1. Paired leg in the same `auto_transfer_group_id` on an account
    ///      in the target currency — bit-exact, the TMA wrote it when the
    ///      transaction happened.
    ///   2. APILayer historical quote on the transaction's date — close to
    ///      the market rate that day.
    ///   3. (Fallback handled by the row: today's rate from CurrencyManager
    ///      with an "approximate" warning badge.)
    private func resolveRates(for rows: [SuspiciousRow]) async {
        let accountsById = Dictionary(
            uniqueKeysWithValues: appViewModel.dataStore.accounts.map { ($0.id, $0) }
        )
        var out: [String: ResolvedRate] = [:]
        for row in rows {
            let tx = row.transaction
            let label = (tx.currency ?? "").uppercased()
            let accountCcy = row.account.currency.uppercased()

            // 1) Pair-extracted — walk the auto-transfer group, find a leg
            //    on an account already in the target (account) currency.
            if let groupId = tx.autoTransferGroupId,
               let pair = appViewModel.dataStore.transactions.first(where: {
                   $0.autoTransferGroupId == groupId
                       && $0.id != tx.id
                       && $0.transferGroupId != nil
                       && ($0.accountId.flatMap { accountsById[$0]?.currency.uppercased() } == accountCcy)
               }),
               tx.amountNative != 0 {
                // `pair.amountNative` is already in the target currency.
                // rate = pair_target_amount / broken_foreign_amount.
                let pairAmount = Decimal(pair.amountNative) / 100
                let brokenAmount = Decimal(tx.amountNative) / 100
                if brokenAmount > 0 {
                    let rate = pairAmount / brokenAmount
                    out[tx.id] = ResolvedRate(rate: rate, source: .pair, date: row.transaction.date)
                    continue
                }
            }

            // 2) Historical quote from APILayer.
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let date = df.date(from: tx.date),
               let quote = await exchangeService.fetchHistoricalRate(
                    from: label, to: accountCcy, date: date) {
                out[tx.id] = ResolvedRate(rate: Decimal(quote), source: .historical, date: tx.date)
                continue
            }

            // 3) No resolved rate — the row will fall back to today's rate.
        }
        resolvedRates = out
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
                        ReconciliationRow(
                            row: row,
                            resolved: resolvedRates[row.transaction.id]
                        ) { decision in
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
            .task {
                await resolveRates(for: suspiciousRows)
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
                //
                // Rate priority:
                //   - Pair-extracted (bit-exact): use the rate TMA wrote
                //     when the transaction happened.
                //   - Historical APILayer quote for `tx.date`.
                //   - Fallback: today's `CurrencyManager.rates` — less
                //     accurate for old rows, but keeps the flow unblocked
                //     when the API is unreachable.
                let cm = appViewModel.currencyManager
                let labelCode = CurrencyCode(rawValue: row.transaction.currency?.uppercased() ?? "") ?? .rub
                let accountCode = row.account.currencyCode
                let originalAmount = row.transaction.amountNative.displayAmount
                let resolved = resolvedRates[row.transaction.id]
                let rate: Decimal = resolved?.rate ?? {
                    let fromRate = Decimal(cm.rates[labelCode.rawValue] ?? 1.0)
                    let toRate = Decimal(cm.rates[accountCode.rawValue] ?? 1.0)
                    return fromRate != 0 ? toRate / fromRate : 1
                }()
                // Safety: refuse to save a 1:1 conversion between different
                // currencies — that's what produced the original bug in
                // the first place.
                guard !(labelCode != accountCode && rate == 1) else {
                    errorMessage = String(localized: "currencyReconciliation.error.rateMissing")
                    return
                }
                let converted = originalAmount * rate
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

/// FX rate resolved for a specific reconciliation row, with provenance so
/// the UI can show "bit-exact pair rate" vs. "historical quote" vs.
/// "approximate" (the default when neither is available).
struct ResolvedRate: Sendable {
    enum Source: Sendable {
        case pair          // extracted from an auto-transfer partner leg
        case historical    // APILayer quote for the tx's date
    }
    let rate: Decimal
    let source: Source
    let date: String
}

private enum ReconciliationDecision {
    case keepAsAccountCurrency
    case reinterpretAsLabel
    case delete
}

private struct ReconciliationRow: View {
    let row: SuspiciousRow
    let resolved: ResolvedRate?
    let onDecision: (ReconciliationDecision) async -> Void

    @Environment(AppViewModel.self) private var appViewModel
    @State private var isActing = false

    private var labelCode: CurrencyCode? {
        guard let raw = row.transaction.currency else { return nil }
        return CurrencyCode(rawValue: raw.uppercased())
    }

    /// Human-readable provenance for the FX rate used. Nil = "today's
    /// live rate" (the fallback) — the UI surfaces an "approximate"
    /// warning for that case.
    private var rateProvenance: (label: String, isApproximate: Bool) {
        guard let resolved else {
            return (String(localized: "currencyReconciliation.rate.approximate"), true)
        }
        switch resolved.source {
        case .pair:
            return (String(localized: "currencyReconciliation.rate.pair"), false)
        case .historical:
            let dateLabel = resolved.date
            return (String(format: String(localized: "currencyReconciliation.rate.historical %@"), dateLabel), false)
        }
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
            // Same priority as `applyDecision`: resolved rate > today's
            // rate. The preview number must match what actually gets
            // saved.
            let rate: Decimal = resolved?.rate ?? {
                let fromRate = Decimal(cm.rates[labelCode.rawValue] ?? 1.0)
                let toRate = Decimal(cm.rates[accountCode.rawValue] ?? 1.0)
                return fromRate != 0 ? toRate / fromRate : 1
            }()
            let converted = amount * rate
            let provenance = rateProvenance

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
                    Text(provenance.label)
                        .font(.caption2)
                        .foregroundStyle(provenance.isApproximate ? .orange : .secondary)
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
