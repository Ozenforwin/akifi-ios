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

struct AccountCarouselView: View {
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

    private var nextIndex: Int { (selectedIndex + 1) % accounts.count }
    private var prevIndex: Int { (selectedIndex - 1 + accounts.count) % accounts.count }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let cardWidth = geo.size.width
                let isDragging = dragOffset != 0

                ZStack {
                    // Stacked cards behind (fade out during drag)
                    ForEach(Array(stackLayers.enumerated()), id: \.offset) { layerIndex, accountIndex in
                        let layerOffset = CGFloat(layerIndex + 1)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(hex: accounts[accountIndex].color).opacity(0.06 + 0.02 * layerOffset))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(hex: accounts[accountIndex].color).opacity(0.08), lineWidth: 0.5)
                            )
                            .frame(height: 190 - layerOffset * 12)
                            .padding(.horizontal, 4 + layerOffset * 12)
                            .offset(y: layerOffset * 6)
                            .opacity(isDragging ? 0 : 1.0 - layerOffset * 0.25)
                    }

                    // Next card (right side)
                    if accounts.count > 1 {
                        cardView(for: nextIndex)
                            .offset(x: dragOffset + cardWidth)
                    }

                    // Previous card (left side)
                    if accounts.count > 1 {
                        cardView(for: prevIndex)
                            .offset(x: dragOffset - cardWidth)
                    }

                    // Active card
                    cardView(for: selectedIndex)
                        .offset(x: dragOffset)
                }
                .clipped()
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
                                let target: CGFloat = goNext ? -cardWidth : cardWidth
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
                .frame(height: 210)
            }
            .frame(height: 210)

            // Custom page dots + add button
            HStack(spacing: 6) {
                ForEach(0..<accounts.count, id: \.self) { index in
                    Capsule()
                        .fill(index == selectedIndex ? Color(hex: accounts[selectedIndex].color) : Color.gray.opacity(0.3))
                        .frame(width: index == selectedIndex ? 20 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: selectedIndex)
                }

                Button {
                    onAddAccount?()
                } label: {
                    Circle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                }
                .accessibilityLabel("Добавить счёт")
            }
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

    /// Indices of accounts to show as stacked layers behind the active card
    private var stackLayers: [Int] {
        guard accounts.count > 1 else { return [] }
        var layers: [Int] = []
        let maxLayers = min(accounts.count - 1, 2)
        for i in 1...maxLayers {
            layers.append((selectedIndex + i) % accounts.count)
        }
        return layers
    }
}

// MARK: - AccountCardView

struct AccountCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let account: Account
    let balance: Int64
    var isBalanceHidden: Bool = false
    var onToggleHidden: (() -> Void)?
    var onTogglePrimary: (() -> Void)?
    var onShare: (() -> Void)?
    var onEdit: (() -> Void)?

    private var accountColor: Color { Color(hex: account.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: icon + action buttons
            HStack {
                // Account icon
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accountColor.opacity(0.10))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(account.icon)
                            .font(.title3)
                    }

                Spacer()

                // Action buttons
                HStack(spacing: 4) {
                    actionButton(
                        icon: isBalanceHidden ? "eye.slash" : "eye",
                        label: isBalanceHidden ? "Показать баланс" : "Скрыть баланс",
                        action: { onToggleHidden?() }
                    )

                    Button {
                        onTogglePrimary?()
                    } label: {
                        Image(systemName: account.isPrimary ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(account.isPrimary ? accountColor : .primary.opacity(0.4))
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .accessibilityLabel(account.isPrimary ? "Основной счёт" : "Сделать основным")

                    actionButton(
                        icon: "square.and.arrow.up",
                        label: "Поделиться",
                        action: { onShare?() }
                    )

                    actionButton(
                        icon: "gearshape",
                        label: "Настройки счёта",
                        action: { onEdit?() }
                    )
                }
            }
            .padding(.bottom, 10)

            // Account name + shared badge
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.7))

                if isSharedAccount {
                    HStack(spacing: 3) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                        Text("Общая")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.bottom, 2)

            // Balance
            Text(appViewModel.currencyManager.formatAmount(balance.displayAmount))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(balance < 0 ? Color.expense : .primary)
                .blur(radius: isBalanceHidden ? 10 : 0)
                .padding(.bottom, 16)

            // Income / Expense pills
            HStack(spacing: 8) {
                incomePill
                expensePill
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        accountColor.opacity(0.10),
                        accountColor.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accountColor.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: accountColor.opacity(0.08), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 4)
    }

    // MARK: - Subviews

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.4))
                .frame(width: 36, height: 36)
                .background(.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityLabel(label)
    }

    private var incomePill: some View {
        HStack(spacing: 4) {
            Text("↑")
                .font(.system(size: 11))
                .foregroundStyle(Color.income)
            Text("+\(appViewModel.currencyManager.formatAmount(monthlyIncome.displayAmount))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.income)
                .blur(radius: isBalanceHidden ? 6 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.income.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var expensePill: some View {
        HStack(spacing: 4) {
            Text("↓")
                .font(.system(size: 11))
                .foregroundStyle(Color.expense)
            Text("-\(appViewModel.currencyManager.formatAmount(monthlyExpense.displayAmount))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.expense)
                .blur(radius: isBalanceHidden ? 6 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.expense.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Computed (using pre-cached values from DataStore)

    private var isSharedAccount: Bool {
        appViewModel.dataStore.profilesMap.count > 1 &&
        appViewModel.dataStore.transactions.lazy.contains { $0.accountId == account.id && $0.userId != appViewModel.dataStore.profile?.id }
    }

    private var monthlyIncome: Int64 {
        appViewModel.dataStore.accountIncome[account.id] ?? 0
    }

    private var monthlyExpense: Int64 {
        appViewModel.dataStore.accountExpense[account.id] ?? 0
    }
}
