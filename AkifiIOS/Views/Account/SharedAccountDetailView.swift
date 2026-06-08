import SwiftUI

/// Detail screen opened when the user taps a shared account in the
/// carousel. Shows the balance, the settlement card (who-owes-whom), a
/// list of recent transactions for that account, and an entry point to
/// invite more members.
struct SharedAccountDetailView: View {
    let account: Account
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(CurrentAccountContext.self) private var currentAccountContext
    @Environment(\.dismiss) private var dismiss

    @State private var showShareSheet = false
    /// Snapshot of `currentAccountContext.accountId` taken on appear, so we
    /// can restore Home's carousel selection (or whatever the previous
    /// writer set) when the user pops back.
    @State private var previousContextAccountId: String?

    /// Settlement state lives in the parent so the period picker (inside
    /// `AccountSettlementCardView`) and the transactions list below stay
    /// synchronised — same period filters both, and a non-empty
    /// `viewModel.suggestions` paints a "pending settlement" badge on
    /// every row in the filtered list until the user closes all debts.
    @State private var settlementVM = SettlementViewModel()

    /// Transaction whose per-member settlement sheet is currently open.
    /// `nil` = no sheet. Driven by tap on the row's status badge.
    @State private var sheetTxn: Transaction?

    /// Members of the shared account with their split weights, fetched
    /// alongside settlement state. Used by the per-txn sheet to compute
    /// each member's share. Empty until `settlementVM.load` returns.
    @State private var memberWeights: [(userId: String, weight: Decimal)] = []

    /// Shared `yyyy-MM-dd` parser for `Transaction.date`.
    private static let txDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    /// Whether to paint the "pending settlement" badge on every visible
    /// transaction. True while there is at least one suggested transfer
    /// in the selected period — i.e. someone still owes someone. Goes
    /// false the moment the user marks all suggestions as settled.
    private var hasOpenSettlements: Bool {
        guard !settlementVM.isLoading else { return false }
        return !settlementVM.suggestions.isEmpty
    }

    /// Settlement-driving transactions on this shared account, scoped
    /// to the period currently selected in the settlement card. The
    /// shared-account detail screen is a "who owes whom" view — it
    /// surfaces only the rows that actually create a debt between
    /// members, not every operation on the account.
    ///
    /// Inclusion rules — the row must satisfy ALL of these:
    /// * sits on this shared account (`accountId == account.id`),
    /// * is an expense (`type == .expense`),
    /// * is NOT a plain manual transfer (`transferGroupId == nil`).
    ///   Note: this is the legacy `transfer_group_id` for hand-rolled
    ///   transfers; the **main expense leg** of an auto-transfer pair
    ///   uses a different field (`autoTransferGroupId`), so it passes
    ///   through here.
    /// * was paid from a *different* account
    ///   (`paymentSourceAccountId != nil` AND `!= account.id`). Direct
    ///   purchases on the shared card are already shared money — no
    ///   one owes anyone for those.
    ///
    /// The settlement card's `viewModel.suggestions` is built from the
    /// same signal, so the list and the debt graph stay in sync.
    private var transactionsForAccount: [Transaction] {
        let interval = settlementVM.selectedPeriod.dateInterval()
        return dataStore.transactions
            .filter { tx in
                guard tx.accountId == account.id,
                      tx.type == .expense,
                      tx.transferGroupId == nil else { return false }
                guard let source = tx.paymentSourceAccountId,
                      source != account.id else { return false }
                guard let d = Self.txDateFormatter.date(from: tx.date) else { return false }
                return interval.contains(d)
            }
            .prefix(100)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                AccountSettlementCardView(
                    sharedAccountId: account.id,
                    currency: account.currency,
                    viewModel: settlementVM
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
        .sheet(item: $sheetTxn) { tx in
            TxnSettlementSheetView(
                transaction: tx,
                sharedAccount: account,
                members: memberWeights,
                payerUserId: payerUserId(for: tx),
                viewModel: settlementVM
            )
            .presentationBackground(.regularMaterial)
        }
        .task(id: account.id) {
            await loadMemberWeights()
        }
        // Override the FAB's contextual account while this detail screen
        // is on top of the navigation stack. Restore the previous value
        // (Home carousel selection) on dismiss so popping back leaves the
        // FAB pointing at the right account.
        .onAppear {
            previousContextAccountId = currentAccountContext.accountId
            currentAccountContext.accountId = account.id
        }
        .onDisappear {
            currentAccountContext.accountId = previousContextAccountId
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
                    transactionRow(for: tx)
                }
            }
        }
    }

    /// One row in the shared-account tx list. Wraps `TransactionRowView`
    /// in a VStack so the per-row settlement state badge fits beneath
    /// without surgery on the shared row component (it's reused across
    /// Home, Search, etc.).
    ///
    /// Three interactions, all converging on the same per-member marks:
    /// 1. Tap the badge → opens the per-member sheet.
    /// 2. Swipe left → quick "Учесть всё" / "Вернуть всё".
    /// 3. (In the sheet) per-member toggles for precise control.
    @ViewBuilder
    private func transactionRow(for tx: Transaction) -> some View {
        let state = settlementState(for: tx)
        Button {
            HapticManager.light()
            sheetTxn = tx
        } label: {
            TransactionRowView(
                transaction: tx,
                category: dataStore.category(for: tx),
                account: account
            )
            // Badge sits in the bottom-right inside the card. Using overlay
            // keeps `TransactionRowView` itself unchanged (it's reused across
            // Home, Search, etc.) — surgery there would ripple. The 12pt
            // inset matches the row's internal padding so the pill aligns
            // with the rest of the row chrome.
            .overlay(alignment: .bottomTrailing) {
                if let state {
                    settlementBadge(for: tx, state: state)
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(state == .full ? 0.55 : 1.0)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            swipeAction(for: tx, state: state ?? .open)
        }
    }

    /// Status capsule shown inside the row card. Color and copy reflect
    /// the txn's per-member settlement state. The whole row is tappable
    /// (parent wraps in a Button), so this view stays purely visual.
    @ViewBuilder
    private func settlementBadge(for tx: Transaction, state: TxnSettleState) -> some View {
        let title = state.localizedTitle(
            settled: settledCount(for: tx),
            total: nonPayerCount(for: tx)
        )
        HStack(spacing: 4) {
            Image(systemName: state.icon)
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.tint.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityLabel(title)
    }

    /// Swipe-to-toggle action. Mirrors the "Учесть всё / Вернуть всё"
    /// bulk action from the sheet — a single horizontal gesture per row.
    @ViewBuilder
    private func swipeAction(for tx: Transaction, state: TxnSettleState) -> some View {
        if state == .full {
            // Only offer "reopen" when the row carries real per-txn marks.
            // A row that's `.full` purely because it predates the settle
            // watermark has nothing to unmark here — it's reopened by
            // cancelling the settlement in the card's history list instead.
            if settledCount(for: tx) > 0 {
                Button {
                    HapticManager.medium()
                    Task {
                        await settlementVM.unmarkTxnSettledForAll(
                            transactionId: tx.id,
                            sharedAccountId: account.id,
                            dataStore: dataStore,
                            currencyManager: cm
                        )
                    }
                } label: {
                    Label(String(localized: "sharedAccount.tx.swipe.reopen"),
                          systemImage: "arrow.uturn.backward")
                }
                .tint(Color.warning)
            }
        } else {
            Button {
                HapticManager.medium()
                Task {
                    await settlementVM.markTxnSettledForAll(
                        transactionId: tx.id,
                        sharedAccountId: account.id,
                        payerUserId: payerUserId(for: tx),
                        memberUserIds: memberWeights.map(\.userId),
                        dataStore: dataStore,
                        currencyManager: cm
                    )
                }
            } label: {
                Label(String(localized: "sharedAccount.tx.swipe.markSettled"),
                      systemImage: "checkmark.seal.fill")
            }
            .tint(Color.income)
        }
    }

    // MARK: - Per-tx settlement state

    enum TxnSettleState: Equatable {
        case open
        case partial
        case full

        var icon: String {
            switch self {
            case .open:    return "hourglass"
            case .partial: return "circle.lefthalf.filled"
            case .full:    return "checkmark.seal.fill"
            }
        }

        var tint: Color {
            switch self {
            case .open:    return .warning
            case .partial: return .accent
            case .full:    return .income
            }
        }

        func localizedTitle(settled: Int, total: Int) -> String {
            switch self {
            case .open:
                return String(localized: "sharedAccount.tx.pendingSettlement")
            case .partial:
                return String(format: String(localized: "sharedAccount.tx.partial %lld %lld"),
                              settled, total)
            case .full:
                return String(localized: "sharedAccount.tx.settledForAll")
            }
        }
    }

    /// Visible state for the per-row badge. Returns nil when there's
    /// nothing meaningful to show — the cumulative balance is even AND the
    /// row is neither per-txn-marked nor covered by a past settle.
    private func settlementState(for tx: Transaction) -> TxnSettleState? {
        let settled = settledCount(for: tx)
        let total = nonPayerCount(for: tx)

        // 1. Explicit per-txn marks win — show their precise state.
        if total > 0 && settled > 0 {
            return settled >= total ? .full : .partial
        }

        // 2. Covered by a cumulative settle: the row is dated on/before the
        //    last "Отметить выполненным" watermark, so its debt is already
        //    folded into a closed settlement. Without this the row flips back
        //    to "Ожидает расчёта" as soon as a *newer* expense reopens the
        //    net debt — the exact "settled rows reappear" bug. See
        //    `SettlementViewModel.settlementWatermark`.
        if isCoveredBySettlement(tx) {
            return .full
        }

        // 3. Otherwise only flag "ожидает" while a net debt is still open —
        //    on a clean account the badge would just be visual noise.
        if !settlementVM.suggestions.isEmpty {
            return .open
        }
        return nil
    }

    /// True when `tx` is dated on or before the last cumulative settle, i.e.
    /// its share is already reconciled by a `settlements` row even though no
    /// per-transaction mark exists for it.
    private func isCoveredBySettlement(_ tx: Transaction) -> Bool {
        guard let watermark = settlementVM.settlementWatermark,
              let txDate = Self.txDateFormatter.date(from: String(tx.date.prefix(10)))
        else { return false }
        return txDate <= watermark
    }

    private func settledCount(for tx: Transaction) -> Int {
        settlementVM.memberSettlementsByTxn[tx.id]?.count ?? 0
    }

    private func nonPayerCount(for tx: Transaction) -> Int {
        // Total members − 1 (the payer doesn't owe their own share).
        max(memberWeights.count - 1, 0)
    }

    /// The user who actually funded this auto-transfer expense — the owner
    /// of the payment-source account, NOT `tx.userId` (which is merely who
    /// recorded the row; the recorder isn't always the payer). Falls back to
    /// `tx.userId` when the source account isn't visible (RLS hides the other
    /// member's personal accounts) — that matches the calculator's own
    /// best-effort attribution.
    private func payerUserId(for tx: Transaction) -> String {
        if let src = tx.paymentSourceAccountId,
           let owner = dataStore.accounts.first(where: { $0.id == src })?.userId {
            return owner
        }
        return tx.userId
    }

    /// Pulls `account_members` once on appear so the per-txn sheet has the
    /// member list with split weights ready. The settlement card already
    /// fetches the same rows in `SettlementViewModel.load`, but the sheet
    /// view needs them in a friendly tuple-list shape.
    private func loadMemberWeights() async {
        do {
            let members: [AccountMember] = try await SupabaseManager.shared.client
                .from("account_members")
                .select()
                .eq("account_id", value: account.id)
                .execute()
                .value
            if !members.isEmpty {
                memberWeights = members.map { ($0.userId, $0.splitWeight) }
            } else {
                let ids = Array(
                    Set(dataStore.transactions
                        .filter { $0.accountId == account.id }
                        .map(\.userId))
                )
                memberWeights = ids.map { ($0, Decimal(1.0)) }
            }
        } catch {
            // Non-fatal — the sheet will fall back to a single-member view
            // if the list is empty, and the row badges will still render
            // from `viewModel.memberSettlementsByTxn` correctly.
            AppLogger.data.debug("memberWeights load: \(error.localizedDescription)")
        }
    }
}
