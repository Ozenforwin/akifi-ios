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

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        let balance = dataStore.balance(for: account)
        let color = Color(hex: account.color)
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.10))
                .frame(width: 48, height: 48)
                .overlay { Text(account.icon).font(.title2) }
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.headline)
                Text(balance < 0
                     ? "-\(cm.formatAmount(balance.displayAmount))"
                     : cm.formatAmount(balance.displayAmount))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(balance < 0 ? Color.expense : .primary)
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var inviteRow: some View {
        Button {
            showShareSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(String(localized: "sharedAccount.inviteMember"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
