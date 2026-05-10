import SwiftUI

/// Per-member settlement detail for a single shared-account transaction.
/// Shown when the user taps a row's status badge in `SharedAccountDetailView`.
///
/// The sheet renders one row per non-payer member, with their share and a
/// toggle. Toggling persists a `transaction_member_settlements` row (or
/// removes one) and reloads the parent's `SettlementViewModel` so the
/// outer balance card recomputes.
///
/// "Учесть всё" / "Вернуть всё" at the bottom is a bulk shortcut over the
/// per-row toggles.
struct TxnSettlementSheetView: View {
    let transaction: Transaction
    let sharedAccount: Account
    /// Every member of the shared account, with their split weight.
    let members: [(userId: String, weight: Decimal)]
    /// Owner of the auto-transfer source leg — they paid for everyone, so
    /// they don't have a settle-row in this sheet.
    let payerUserId: String
    @Bindable var viewModel: SettlementViewModel

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }
    private var settledIds: Set<String> {
        viewModel.memberSettlementsByTxn[transaction.id] ?? []
    }
    private var nonPayerMembers: [(userId: String, weight: Decimal)] {
        members.filter { $0.userId != payerUserId }
    }
    private var allClosed: Bool {
        !nonPayerMembers.isEmpty &&
            nonPayerMembers.allSatisfy { settledIds.contains($0.userId) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCard
                    membersList
                    bulkButton
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "txnSettle.sheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryCard: some View {
        let category = dataStore.category(for: transaction)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accent.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(category?.icon ?? "💸").font(.title3)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(transaction.description ?? category?.name ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(cm.formatAmount(abs(transaction.amountNative).displayAmount))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.expense)
            }

            HStack(spacing: 6) {
                Image(systemName: "creditcard.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: String(localized: "txnSettle.sheet.paidBy %@"),
                            payerName))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Members list

    @ViewBuilder
    private var membersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "txnSettle.sheet.sharesHeader"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(nonPayerMembers.enumerated()), id: \.element.userId) { idx, m in
                    memberRow(userId: m.userId, share: shareFor(m))
                    if idx < nonPayerMembers.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    @ViewBuilder
    private func memberRow(userId: String, share: Decimal) -> some View {
        let isSettled = settledIds.contains(userId)
        Button {
            HapticManager.light()
            Task {
                if isSettled {
                    await viewModel.unmarkTxnShareSettled(
                        transactionId: transaction.id,
                        sharedAccountId: sharedAccount.id,
                        settledForUserId: userId,
                        dataStore: dataStore,
                        currencyManager: cm
                    )
                } else {
                    await viewModel.markTxnShareSettled(
                        transactionId: transaction.id,
                        sharedAccountId: sharedAccount.id,
                        settledForUserId: userId,
                        dataStore: dataStore,
                        currencyManager: cm
                    )
                }
            }
        } label: {
            HStack(spacing: 12) {
                memberAvatar(for: userId)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name(for: userId))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(String(format: String(localized: "txnSettle.sheet.share %@"),
                                cm.formatAmount(share)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSettled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSettled ? Color.income : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bulk action

    @ViewBuilder
    private var bulkButton: some View {
        Button {
            HapticManager.medium()
            Task {
                if allClosed {
                    await viewModel.unmarkTxnSettledForAll(
                        transactionId: transaction.id,
                        sharedAccountId: sharedAccount.id,
                        dataStore: dataStore,
                        currencyManager: cm
                    )
                } else {
                    await viewModel.markTxnSettledForAll(
                        transactionId: transaction.id,
                        sharedAccountId: sharedAccount.id,
                        payerUserId: payerUserId,
                        memberUserIds: members.map(\.userId),
                        dataStore: dataStore,
                        currencyManager: cm
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: allClosed ? "arrow.uturn.backward" : "checkmark.seal.fill")
                    .font(.subheadline.weight(.bold))
                Text(allClosed
                     ? String(localized: "txnSettle.sheet.unmarkAll")
                     : String(localized: "txnSettle.sheet.markAll"))
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: allClosed
                        ? [Color.warning, Color.warning.opacity(0.85)]
                        : [Color.income, Color.income.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(nonPayerMembers.isEmpty)
    }

    // MARK: - Helpers

    private func shareFor(_ m: (userId: String, weight: Decimal)) -> Decimal {
        let total = abs(Decimal(transaction.amountNative))
        let sumWeights = members.map(\.weight).reduce(0, +)
        guard sumWeights > 0 else { return 0 }
        return (total * m.weight / sumWeights) / 100  // kopecks → major units
    }

    private var formattedDate: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: String(transaction.date.prefix(10))) else { return transaction.date }
        let display = DateFormatter()
        display.locale = Locale.current
        display.dateStyle = .medium
        return display.string(from: d)
    }

    private func name(for userId: String) -> String {
        if let p = dataStore.profilesMap[userId], let n = p.fullName, !n.isEmpty {
            return n
        }
        if userId == dataStore.profile?.id {
            return dataStore.profile?.fullName ?? String(localized: "common.you")
        }
        return String(userId.prefix(6))
    }

    private var payerName: String { name(for: payerUserId) }

    @ViewBuilder
    private func memberAvatar(for userId: String) -> some View {
        let profile = dataStore.profilesMap[userId]
        let letter = String((profile?.fullName?.first ?? "?")).uppercased()
        ZStack {
            if let urlStr = profile?.avatarUrl, let url = URL(string: urlStr) {
                CachedAsyncImage(url: url) { initialsBubble(letter: letter) }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                initialsBubble(letter: letter)
            }
        }
    }

    @ViewBuilder
    private func initialsBubble(letter: String) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.accent.opacity(0.45), Color.accent.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 32, height: 32)
            .overlay { Text(letter).font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
    }
}
