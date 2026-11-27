import SwiftUI

// MARK: - Hidden Balances Storage

private enum HiddenBalancesStore {
    private static let key = "akifi-hidden-balances"

    static func get() -> Set<String> {
        guard let array = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(array)
    }

    static func set(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func toggle(_ accountId: String) -> Set<String> {
        var ids = get()
        if ids.contains(accountId) {
            ids.remove(accountId)
        } else {
            ids.insert(accountId)
        }
        set(ids)
        return ids
    }
}

// MARK: - AccountCarouselView

/// Home's hero: one account card at a time, swiped left / right (wrapping
/// around). The card is content, not glass, washed in the account's own
/// colour (`.akifiCard(tint:)` — Vladimir: the white cards lost which
/// account is which, 2026-11-28); the colour also marks the icon tile, the
/// primary star and the selected page dot.
struct AccountCarouselView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let accounts: [Account]
    @Binding var selectedIndex: Int
    let balanceFor: (Account) -> Int64
    var onAddAccount: (() -> Void)?
    var onEditAccount: ((Account) -> Void)?
    var onShareAccount: ((Account) -> Void)?
    var onSetPrimary: ((Account) -> Void)?

    @State private var hiddenBalances: Set<String> = HiddenBalancesStore.get()
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false
    /// The carousel's width — one card. Measured (instead of a
    /// `GeometryReader` with a fixed height), so the card's height follows
    /// its content and grows with Dynamic Type.
    @State private var cardWidth: CGFloat = 0

    /// Gap between neighbouring cards while they are dragged.
    static let cardSpacing: CGFloat = 12

    private var nextIndex: Int { (selectedIndex + 1) % accounts.count }
    private var prevIndex: Int { (selectedIndex - 1 + accounts.count) % accounts.count }

    /// Distance between the leading edges of neighbouring cards.
    private var pageStride: CGFloat { cardWidth + Self.cardSpacing }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                // Neighbours one stride to either side, dragged together
                // with the active card.
                if accounts.count > 1 {
                    cardView(for: nextIndex)
                        .offset(x: dragOffset + pageStride)
                        .accessibilityHidden(true)
                    cardView(for: prevIndex)
                        .offset(x: dragOffset - pageStride)
                        .accessibilityHidden(true)
                }

                cardView(for: selectedIndex)
                    .offset(x: dragOffset)
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                accounts.count > 1
                ? DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        guard !isAnimating else { return }
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        guard !isAnimating else { return }
                        let threshold = cardWidth * 0.2
                        let goNext = value.translation.width < -threshold || value.predictedEndTranslation.width < -cardWidth * 0.4
                        let goPrev = value.translation.width > threshold || value.predictedEndTranslation.width > cardWidth * 0.4

                        if goNext || goPrev {
                            isAnimating = true
                            let newIndex = goNext ? nextIndex : prevIndex
                            let target: CGFloat = goNext ? -pageStride : pageStride
                            withAnimation(.easeOut(duration: 0.25)) {
                                dragOffset = target
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                                // Update both atomically to prevent flicker
                                selectedIndex = newIndex
                                dragOffset = 0
                                isAnimating = false
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                dragOffset = 0
                            }
                        }
                    }
                : nil
            )

            pageControl
        }
        // Membership drives the "shared" badge (B7). Re-checked when the
        // account list changes (new account, accepted invite); the store
        // throttles to one round-trip per minute.
        .task(id: accounts.map(\.id)) {
            await appViewModel.dataStore.accountMembership.refresh(viewerId: appViewModel.dataStore.profile?.id)
        }
    }

    // MARK: - Page control

    /// Page dots (the selected one in the account's colour) and the
    /// add-account button. For VoiceOver the dots are one adjustable
    /// element — swipe up / down switches the account, which the custom
    /// drag doesn't offer.
    private var pageControl: some View {
        HStack(spacing: 4) {
            if accounts.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<accounts.count, id: \.self) { index in
                        Capsule()
                            .fill(index == selectedIndex ? Color(hex: accounts[index].color) : Color(.tertiaryLabel))
                            .frame(width: index == selectedIndex ? 20 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: selectedIndex)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(String(localized: "common.account"))
                .accessibilityValue(Text(verbatim: accounts.indices.contains(selectedIndex) ? accounts[selectedIndex].name : ""))
                .accessibilityAdjustableAction { direction in
                    guard !isAnimating else { return }
                    switch direction {
                    case .increment: selectedIndex = nextIndex
                    case .decrement: selectedIndex = prevIndex
                    @unknown default: break
                    }
                }
            }

            Button {
                onAddAccount?()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "home.addAccount"))
        }
    }

    private func cardView(for index: Int) -> some View {
        let account = accounts[index]
        return AccountCardView(
            account: account,
            balance: balanceFor(account),
            isBalanceHidden: hiddenBalances.contains(account.id),
            onToggleHidden: {
                hiddenBalances = HiddenBalancesStore.toggle(account.id)
            },
            onTogglePrimary: {
                onSetPrimary?(account)
            },
            onShare: {
                onShareAccount?(account)
            },
            onEdit: {
                onEditAccount?(account)
            }
        )
    }
}

// MARK: - AccountCardView

/// One account in the carousel: icon tile, name, balance and this month's
/// income / expense. Hiding the balance is one tap next to the amount; the
/// rarer actions (primary, share, settings) live in the «…» menu.
struct AccountCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let account: Account
    let balance: Int64
    var isBalanceHidden: Bool = false
    var onToggleHidden: (() -> Void)?
    var onTogglePrimary: (() -> Void)?
    var onShare: (() -> Void)?
    var onEdit: (() -> Void)?

    @ScaledMetric(relativeTo: .title3) private var iconTileSize: CGFloat = 40
    /// The card keeps the pre-1.6 presence (≈190 pt with padding) — the
    /// content-hugging card looked like a thin strip (Vladimir,
    /// 2026-11-28). Grows with Dynamic Type; content can still exceed it.
    @ScaledMetric(relativeTo: .body) private var contentMinHeight: CGFloat = 158

    private var accountColor: Color { Color(hex: account.color) }
    private var fmt: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Balance at the bottom edge, like a card in Wallet.
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                balanceRow
                monthFlowRow
            }
        }
        .frame(minHeight: contentMinHeight, alignment: .topLeading)
        .akifiCard(tint: accountColor)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Text(account.icon)
                .font(.title3)
                .frame(width: iconTileSize, height: iconTileSize)
                .background(accountColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(account.name)
                        .font(.headline)
                        .lineLimit(1)
                    if account.isPrimary {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(accountColor)
                            .accessibilityLabel(String(localized: "account.primary"))
                    }
                }

                if isSharedAccount {
                    Label(String(localized: "categories.shared"), systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            actionsMenu
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                onTogglePrimary?()
            } label: {
                if account.isPrimary {
                    Label(String(localized: "account.primary"), systemImage: "star.fill")
                } else {
                    Label(String(localized: "account.setPrimary"), systemImage: "star")
                }
            }
            // Already primary: the row only says so (tapping the filled
            // star was a no-op before, too).
            .disabled(account.isPrimary)

            Button {
                onShare?()
            } label: {
                Label(String(localized: "common.share"), systemImage: "square.and.arrow.up")
            }

            Divider()

            Button {
                onEdit?()
            } label: {
                Label(String(localized: "account.settings"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "account.actions"))
    }

    private var balanceRow: some View {
        HStack(spacing: 4) {
            Text(verbatim: balance < 0
                 ? "-\(fmt.formatAmount(balance.displayAmount))"
                 : fmt.formatAmount(balance.displayAmount))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(balance < 0 ? Color.expense : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .blur(radius: isBalanceHidden ? 10 : 0)
                // A hidden balance stays hidden from VoiceOver too.
                .accessibilityHidden(isBalanceHidden)

            Button {
                onToggleHidden?()
            } label: {
                Image(systemName: isBalanceHidden ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isBalanceHidden ? String(localized: "account.showBalance") : String(localized: "account.hideBalance"))

            Spacer(minLength: 0)
        }
    }

    /// This month's income and expense on the account — side by side, one
    /// under the other when they don't fit (large Dynamic Type).
    private var monthFlowRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                incomeLabel
                expenseLabel
            }
            VStack(alignment: .leading, spacing: 4) {
                incomeLabel
                expenseLabel
            }
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
    }

    private var incomeLabel: some View {
        flowLabel(
            text: "+\(fmt.formatAmount(monthlyIncome.displayAmount))",
            systemImage: "arrow.up.right",
            color: Color.income,
            accessibilityTitle: String(localized: "summary.monthlyIncome")
        )
    }

    private var expenseLabel: some View {
        flowLabel(
            text: "-\(fmt.formatAmount(monthlyExpense.displayAmount))",
            systemImage: "arrow.down.left",
            color: Color.expense,
            accessibilityTitle: String(localized: "summary.monthlyExpense")
        )
    }

    private func flowLabel(text: String, systemImage: String, color: Color, accessibilityTitle: String) -> some View {
        Label {
            Text(verbatim: text)
                .blur(radius: isBalanceHidden ? 6 : 0)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(Text(verbatim: isBalanceHidden ? "" : text))
    }

    // MARK: - Computed (using pre-cached values from DataStore)

    /// B7: membership (`account_members`), not "someone else wrote a row".
    /// The legacy heuristic only bridges the first frames until
    /// membership snapshot has loaded.
    private var isSharedAccount: Bool {
        let dataStore = appViewModel.dataStore
        return AccountSharingIndex.isShared(account, dataStore: dataStore, currentUserId: dataStore.profile?.id)
    }

    /// The pills are "this month", not lifetime totals (they used to show
    /// `accountIncome` / `accountExpense`, which sum the whole history and
    /// count transfer legs as income/expense).
    private var monthFlow: MonthlyAggregate {
        appViewModel.dataStore.currentMonthFlow(for: account)
    }

    private var monthlyIncome: Int64 { monthFlow.income }

    private var monthlyExpense: Int64 { monthFlow.expense }
}
