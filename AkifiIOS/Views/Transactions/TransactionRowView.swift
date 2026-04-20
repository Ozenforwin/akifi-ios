import SwiftUI

struct TransactionRowView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transaction: Transaction
    let category: Category?
    var account: Account?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isTransfer: Bool { transaction.type == .transfer || transaction.transferGroupId != nil }
    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        HStack(spacing: 12) {
            // Category icon with creator badge
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(iconEmoji)
                            .font(.title3)
                    }

                // Creator avatar badge (for shared accounts — show for all users including self)
                if isOnSharedAccount,
                   let creator = appViewModel.dataStore.profilesMap[transaction.userId] {
                    creatorBadge(creator)
                        .offset(x: 4, y: 4)
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: Category name + amount
                HStack(alignment: .firstTextBaseline) {
                    Text(titleText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formattedAmount)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(amountColor)
                            .monospacedDigit()
                        if let preview = displayCurrencyPreview {
                            Text(preview)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }

                // Row 2: Date + account badge
                HStack(spacing: 6) {
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let acc = resolvedAccount {
                        accountBadge(acc)
                    }
                }

                // Row 3: Description or transfer direction
                if isTransfer {
                    if let desc = transaction.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    // Show "Account A → Account B" for transfers
                    if let directionText = transferDirectionText {
                        Text(directionText)
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                } else if let desc = transaction.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // Row 4: "From {source}" badge for auto-transferred expenses
                if let sourceName = paymentSourceName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.system(size: 10))
                        Text(String(format: String(localized: "tx.autoTransfer.badge"), sourceName))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.accent.opacity(0.24), lineWidth: 0.5)
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .primary.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: - Computed

    private var iconEmoji: String {
        isTransfer ? "↔️" : (category?.icon ?? "📦")
    }

    private var iconBackground: Color {
        if isTransfer {
            return Color.transfer.opacity(0.08)
        }
        return Color(hex: category?.color ?? "#888888").opacity(0.08)
    }

    private var titleText: String {
        isTransfer ? String(localized: "transaction.transfer") : (category?.name ?? String(localized: "transaction.noCategory"))
    }

    /// True if this transaction's account has transactions from multiple users
    private var isOnSharedAccount: Bool {
        guard dataStore.profilesMap.count > 1, let accId = transaction.accountId else { return false }
        let myId = dataStore.profile?.id
        return dataStore.transactions.lazy.contains { $0.accountId == accId && $0.userId != myId }
    }

    private var resolvedAccount: Account? {
        if let account { return account }
        guard let accId = transaction.accountId else { return nil }
        return dataStore.accounts.first { $0.id == accId }
    }

    /// Name of the personal source account for auto-transferred expenses,
    /// or `nil` for ordinary rows. Only surfaces on the main expense-leg
    /// (payment_source_account_id is set exclusively there).
    private var paymentSourceName: String? {
        guard let sourceId = transaction.paymentSourceAccountId,
              sourceId != transaction.accountId,
              let source = dataStore.accounts.first(where: { $0.id == sourceId }) else {
            return nil
        }
        return source.name
    }

    private var amountColor: Color {
        if isTransfer {
            return Color.transfer
        }
        switch transaction.type {
        case .income: return Color.income
        case .expense: return Color.expense
        case .transfer: return Color.transfer
        }
    }

    /// Build "Account A → Account B" direction text for transfers.
    /// Works even when the pair transaction is not accessible (e.g. on another user's private account).
    private var transferDirectionText: String? {
        guard transaction.transferGroupId != nil || transaction.isTransfer else { return nil }
        let currentName = resolvedAccount?.name ?? "?"

        if let groupId = transaction.transferGroupId,
           let pair = dataStore.transactions.first(where: { $0.transferGroupId == groupId && $0.id != transaction.id }),
           let pairAccountId = pair.accountId,
           let pairAccount = dataStore.accounts.first(where: { $0.id == pairAccountId }) {
            // Both sides available
            let fromName = transaction.amount < 0 ? currentName : pairAccount.name
            let toName = transaction.amount < 0 ? pairAccount.name : currentName
            return "\(fromName) → \(toName)"
        }

        // Pair not accessible — show partial direction
        if transaction.amount < 0 {
            return "\(currentName) →"
        } else {
            return "→ \(currentName)"
        }
    }

    /// ADR-001 display rule: surface what the user actually entered.
    ///   1. If `foreignAmount` + `foreignCurrency` are set, the user typed in
    ///      a non-account currency — show that original value with the entry
    ///      currency's symbol.
    ///   2. Otherwise the entry was native — show `amountNative` with the
    ///      account's currency symbol.
    /// We never run this through `currencyManager.formatAmount` because that
    /// converts to the user's display preference and slaps the global symbol
    /// on top, which made VND/USD entries appear as RUB and triggered the
    /// 2 000 000 VND → 26 277 USD report (2026-04-19).
    private var formattedAmount: String {
        let cm = appViewModel.currencyManager
        let sign: String
        switch transaction.type {
        case .income:   sign = isTransfer ? "" : "+"
        case .expense:  sign = isTransfer ? "" : "-"
        case .transfer: sign = ""
        }

        if let fAmount = transaction.foreignAmount,
           let fCcyRaw = transaction.foreignCurrency,
           let fCode = CurrencyCode(rawValue: fCcyRaw.uppercased()) {
            return "\(sign)\(cm.formatInCurrency(abs(fAmount), currency: fCode))"
        }

        let nativeAmount = abs(transaction.amountNative.displayAmount)
        let accountCcy = resolvedAccount?.currencyCode
            ?? transaction.currency.flatMap { CurrencyCode(rawValue: $0.uppercased()) }
            ?? cm.dataCurrency
        return "\(sign)\(cm.formatInCurrency(nativeAmount, currency: accountCcy))"
    }

    private var formattedDate: String {
        transaction.formattedDateTime
    }

    /// Secondary line under the main amount: the same value converted into
    /// the user's selected display currency. Returns nil when the entry is
    /// already in the display currency or when FX rates are missing — in
    /// the latter case lying with `1.0` would be worse than no preview.
    private var displayCurrencyPreview: String? {
        let cm = appViewModel.currencyManager

        let nativeCcy: CurrencyCode
        let nativeAmount: Decimal
        if let fAmount = transaction.foreignAmount,
           let fCcyRaw = transaction.foreignCurrency,
           let fCode = CurrencyCode(rawValue: fCcyRaw.uppercased()) {
            nativeCcy = fCode
            nativeAmount = abs(fAmount)
        } else {
            nativeCcy = resolvedAccount?.currencyCode
                ?? transaction.currency.flatMap { CurrencyCode(rawValue: $0.uppercased()) }
                ?? cm.dataCurrency
            nativeAmount = abs(transaction.amountNative.displayAmount)
        }

        let displayCcy = cm.selectedCurrency
        guard displayCcy != nativeCcy else { return nil }
        guard let fromRate = cm.rates[nativeCcy.rawValue], fromRate > 0,
              let toRate   = cm.rates[displayCcy.rawValue], toRate > 0 else {
            return nil
        }

        let amountInDisplay = nativeAmount / Decimal(fromRate) * Decimal(toRate)
        return "≈ \(cm.formatInCurrency(amountInDisplay, currency: displayCcy))"
    }

    // MARK: - Subviews

    private func creatorBadge(_ creator: Profile) -> some View {
        ZStack {
            if let avatarUrl = creator.avatarUrl, let url = URL(string: avatarUrl) {
                CachedAsyncImage(url: url) {
                    initialsCircle(creator)
                }
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            } else {
                initialsCircle(creator)
            }
        }
    }

    private func initialsCircle(_ creator: Profile) -> some View {
        Circle()
            .fill(Color(.systemGray4))
            .frame(width: 18, height: 18)
            .overlay {
                Text(String((creator.fullName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
    }

    private func accountBadge(_ acc: Account) -> some View {
        HStack(spacing: 3) {
            Text(acc.icon)
                .font(.system(size: 10))
            Text(acc.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
