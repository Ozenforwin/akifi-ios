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

    private struct ListKey: Equatable {
        let revision: DerivationRevision
        let interval: DateInterval
    }

    /// The settlement-driving rows for the selected period, recomputed only
    /// when the data or the period changes (it was a filter + date parse
    /// over every transaction, twice per render).
    @State private var listMemo = Memo<ListKey, [Transaction]>()

    /// Shared `yyyy-MM-dd` parser for `Transaction.date`.
    private static var txDateFormatter: DateFormatter { AppDateFormatters.utcDate }

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
        let key = ListKey(
            revision: dataStore.derivationRevision,
            interval: settlementVM.selectedPeriod.transactionInterval()
        )
        return listMemo.value(for: key) {
            Self.settlementRows(dataStore.transactions, accountId: account.id, interval: key.interval)
        }
    }

    static func settlementRows(_ transactions: [Transaction], accountId: String, interval: DateInterval) -> [Transaction] {
        var dayCache: [String: Date?] = [:]
        var out: [Transaction] = []
        for tx in transactions {
            guard tx.accountId == accountId,
                  tx.type == .expense,
                  tx.transferGroupId == nil else { continue }
            guard let source = tx.paymentSourceAccountId,
                  source != accountId else { continue }
            let day: Date?
            if let cached = dayCache[tx.date] {
                day = cached
            } else {
                day = txDateFormatter.date(from: tx.date)
                dayCache[tx.date] = day
            }
            guard let day, interval.contains(day) else { continue }
            out.append(tx)
            if out.count == 100 { break }
        }
        return out
    }

    /// Members with split weights for the per-txn sheet and the bulk
    /// actions — from the app-wide `account_members` snapshot (P7: this
    /// screen used to fetch the same rows the settlement card fetches).
    /// Falls back to the transaction authors, weight 1, while unknown.
    private var memberWeights: [(userId: String, weight: Decimal)] {
        if let members = dataStore.accountMembership.members(of: account.id, viewerId: dataStore.profile?.id),
           !members.isEmpty {
            return members.map { ($0.userId, $0.splitWeight) }
        }
        let authors = dataStore.derivedCache.transactionIndex(for: dataStore).authorsByAccount[account.id] ?? []
        return authors.sorted().map { ($0, Decimal(1)) }
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
                PersonalDebtCard(account: account, viewModel: settlementVM)
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
        }
        .sheet(item: $sheetTxn) { tx in
            TxnSettlementSheetView(
                transaction: tx,
                sharedAccount: account,
                members: memberWeights,
                payerUserId: payerUserId(for: tx),
                viewModel: settlementVM
            )
        }
        .task(id: account.id) {
            // Shared app-wide snapshot; refetched only when older than 5 min.
            await dataStore.accountMembership.refresh(viewerId: dataStore.profile?.id, maxAge: 300)
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

    /// Members for the avatar row — the same signal as the settlement card
    /// (`account_members`, falling back to transaction authors). Read once
    /// per header render; it was an O(N) filter + sort per read, four reads
    /// per render.
    private var participantUserIds: [String] {
        let ids = memberWeights.map(\.userId)
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

    /// The account's cover (the same photo as its Home card), once loaded.
    private var coverPath: String? {
        dataStore.accounts.first { $0.id == account.id }?.coverPath ?? account.coverPath
    }

    @ViewBuilder
    private var header: some View {
        let balance = dataStore.balance(for: account)
        let color = Color(hex: account.color)
        let participants = participantUserIds
        let cover = appViewModel.accountCovers.image(for: coverPath)
        let palette: AccountCardPalette = cover == nil ? .tinted(color) : .cover
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cover == nil ? color.opacity(0.14) : palette.iconTileFill)
                    .frame(width: 52, height: 52)
                    .overlay { Text(account.icon).font(.title2) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(cover == nil ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(palette.primary))
                    Text(balance < 0
                         ? "-\(cm.formatAmount(balance.displayAmount))"
                         : cm.formatAmount(balance.displayAmount))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(balance < 0 ? palette.expense : palette.primary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                Spacer()
            }

            // Participants row — small avatars stacked with light overlap.
            if !participants.isEmpty {
                HStack(spacing: -6) {
                    ForEach(participants.prefix(5), id: \.self) { uid in
                        participantAvatar(uid)
                    }
                    if participants.count > 5 {
                        Text("+\(participants.count - 5)")
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
        .background {
            if let cover {
                // The Home card's photo; text spans the whole header here,
                // so the scrim is even (as strong as its stronger band).
                AccountCoverBackdrop(cover: cover, uniformScrim: true, dim: account.coverDim)
            } else {
                shape.fill(
                    LinearGradient(
                        colors: [color.opacity(0.08), color.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
        .clipShape(shape)
        .overlay {
            if cover == nil {
                shape.stroke(color.opacity(0.18), lineWidth: 0.5)
            }
        }
        .task(id: coverPath) {
            await appViewModel.accountCovers.load(coverPath)
        }
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

    /// Per-render settlement context shared by every row: the marks index
    /// and the watermark are computed properties on the view model (a
    /// dictionary build and an ISO-8601 parse of every settlement), so they
    /// are read once here instead of 2–3 times per row.
    struct RowContext {
        let marks: [String: Set<String>]
        let watermark: Date?
        let hasSuggestions: Bool
        let members: [(userId: String, weight: Decimal)]

        func settledCount(_ tx: Transaction) -> Int { marks[tx.id]?.count ?? 0 }
        /// Total members − 1 (the payer doesn't owe their own share).
        var nonPayerCount: Int { max(members.count - 1, 0) }
    }

    @ViewBuilder
    private var transactionsSection: some View {
        let rows = transactionsForAccount
        if !rows.isEmpty {
            let context = RowContext(
                marks: settlementVM.memberSettlementsByTxn,
                watermark: settlementVM.settlementWatermark,
                hasSuggestions: !settlementVM.suggestions.isEmpty,
                members: memberWeights
            )
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "transactions.recent"))
                    .font(.headline)
                ForEach(rows) { tx in
                    transactionRow(for: tx, context: context)
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
    /// 1. Tap the row → opens the per-member sheet.
    /// 2. Long-press → quick "Учесть всё" / "Вернуть всё". (These were
    ///    `.swipeActions`, which only work inside a `List` — in this
    ///    ScrollView they were unreachable.)
    /// 3. (In the sheet) per-member toggles for precise control.
    @ViewBuilder
    private func transactionRow(for tx: Transaction, context: RowContext) -> some View {
        let state = Self.settlementState(for: tx, context: context)
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
                    settlementBadge(for: tx, state: state, context: context)
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(state == .full ? 0.55 : 1.0)
        .contextMenu {
            // M7: no recording on approximate (offline) numbers.
            if settlementVM.canRecordSettlements {
                quickAction(for: tx, state: state ?? .open, context: context)
            }
        }
    }

    /// Status capsule shown inside the row card. Color and copy reflect
    /// the txn's per-member settlement state. The whole row is tappable
    /// (parent wraps in a Button), so this view stays purely visual.
    @ViewBuilder
    private func settlementBadge(for tx: Transaction, state: TxnSettleState, context: RowContext) -> some View {
        let title = state.localizedTitle(
            settled: context.settledCount(tx),
            total: context.nonPayerCount
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

    /// Quick toggle (context menu). Mirrors the "Учесть всё / Вернуть всё"
    /// bulk action from the sheet.
    @ViewBuilder
    private func quickAction(for tx: Transaction, state: TxnSettleState, context: RowContext) -> some View {
        if state == .full {
            // Only offer "reopen" when the row carries real per-txn marks.
            // A row that's `.full` purely because it predates the settle
            // watermark has nothing to unmark here — it's reopened by
            // cancelling the settlement in the card's history list instead.
            if context.settledCount(tx) > 0 {
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
                        memberUserIds: context.members.map(\.userId),
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
    static func settlementState(for tx: Transaction, context: RowContext) -> TxnSettleState? {
        let settled = context.settledCount(tx)
        let total = context.nonPayerCount

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
        if isCoveredBySettlement(tx, watermark: context.watermark) {
            return .full
        }

        // 3. Otherwise only flag "ожидает" while a net debt is still open —
        //    on a clean account the badge would just be visual noise.
        if context.hasSuggestions {
            return .open
        }
        return nil
    }

    /// True when `tx` happened at or before the last cumulative settle, i.e.
    /// its share is already reconciled by a `settlements` row even though no
    /// per-transaction mark exists for it. Compares the row's time, not the
    /// UTC midnight of its day (D11) — and in ONE frame (M6): the row's time
    /// is a local wall clock labelled UTC, `settled_at` a real instant, so
    /// the watermark is moved onto the wall clock of `timeZone` first.
    static func isCoveredBySettlement(_ tx: Transaction, watermark: Date?, timeZone: TimeZone = .current) -> Bool {
        guard let watermark else { return false }
        let wallClock = TransactionInstant.parse(tx.rawDateTime)
            ?? txDateFormatter.date(from: String(tx.date.prefix(10)))
        guard let wallClock else { return false }
        return wallClock <= TransactionInstant.wallClock(of: watermark, in: timeZone)
    }

    /// The user who actually funded this auto-transfer expense. The server's
    /// attribution (`get_account_settlement.payers`) wins — it is the same one
    /// the balances were computed with, and identical on every member's phone.
    /// Offline fallback: the owner of the payment-source account when visible,
    /// else `tx.userId` (RLS hides the other member's personal accounts; the
    /// auto-transfer RPC records all legs as the payer).
    private func payerUserId(for tx: Transaction) -> String {
        if let serverPayer = settlementVM.serverPayers[tx.id] {
            return serverPayer
        }
        // Only a MEMBER can be the payer — the server's rule (M10).
        if let src = tx.paymentSourceAccountId,
           let owner = dataStore.accounts.first(where: { $0.id == src })?.userId,
           memberWeights.contains(where: { $0.userId == owner }) {
            return owner
        }
        return tx.userId
    }
}
