import SwiftUI

/// Detail screen opened when the user taps a shared account in the
/// carousel. Shows the balance, the settlement card (who-owes-whom), a
/// list of recent transactions for that account, and an entry point to
/// invite more members.
struct SharedAccountDetailView: View {
    let account: Account
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showShareSheet = false

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var transactionsForAccount: [Transaction] {
        dataStore.transactions
            .filter { $0.accountId == account.id }
            .prefix(30)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                AccountSettlementCardView(
                    sharedAccountId: account.id,
                    currency: account.currency
                )
                inviteRow
                transactionsSection
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ShareAccountView(account: account)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    /// User IDs that have any transaction on this account — treated as
    /// "members" for the avatar row display. Draws from the same signal
    /// as the settlement card so the row stays consistent with the ledger.
    private var participantUserIds: [String] {
        let ids = Array(
            Set(dataStore.transactions
                .filter { $0.accountId == account.id }
                .map(\.userId))
        )
        // Stable ordering: owner first, then alpha by name, fall back to id.
        return ids.sorted { a, b in
            if a == account.userId { return true }
            if b == account.userId { return false }
            let na = dataStore.profilesMap[a]?.fullName ?? a
            let nb = dataStore.profilesMap[b]?.fullName ?? b
            return na < nb
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        let balance = dataStore.balance(for: account)
        let color = Color(hex: account.color)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 52, height: 52)
                    .overlay { Text(account.icon).font(.title2) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.7))
                    Text(balance < 0
                         ? "-\(cm.formatAmount(balance.displayAmount))"
                         : cm.formatAmount(balance.displayAmount))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(balance < 0 ? Color.expense : .primary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                Spacer()
            }

            // Participants row — small avatars stacked with light overlap.
            if !participantUserIds.isEmpty {
                HStack(spacing: -6) {
                    ForEach(participantUserIds.prefix(5), id: \.self) { uid in
                        participantAvatar(uid)
                    }
                    if participantUserIds.count > 5 {
                        Text("+\(participantUserIds.count - 5)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.08), color.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func participantAvatar(_ userId: String) -> some View {
        let profile = dataStore.profilesMap[userId]
        let letter = String((profile?.fullName?.first ?? "?")).uppercased()
        ZStack {
            if let urlStr = profile?.avatarUrl, let url = URL(string: urlStr) {
                CachedAsyncImage(url: url) {
                    fallbackBubble(letter: letter)
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            } else {
                fallbackBubble(letter: letter)
            }
        }
        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
    }

    @ViewBuilder
    private func fallbackBubble(letter: String) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.accent.opacity(0.55), Color.accent.opacity(0.30)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 28, height: 28)
            .overlay {
                Text(letter)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    @ViewBuilder
    private var inviteRow: some View {
        Button {
            HapticManager.light()
            showShareSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LinearGradient(
                            colors: [Color.accent, Color.accent.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(String(localized: "sharedAccount.inviteMember"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var transactionsSection: some View {
        if !transactionsForAccount.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "transactions.recent"))
                    .font(.headline)
                ForEach(transactionsForAccount) { tx in
                    TransactionRowView(
                        transaction: tx,
                        category: dataStore.category(for: tx),
                        account: account
                    )
                }
            }
        }
    }
}
