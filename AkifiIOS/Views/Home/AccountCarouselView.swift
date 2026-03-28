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

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $selectedIndex) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    AccountCardView(
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
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 190)

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
                    // Eye — hide/show balance
                    actionButton(
                        icon: isBalanceHidden ? "eye.slash" : "eye",
                        label: isBalanceHidden ? "Показать баланс" : "Скрыть баланс",
                        action: { onToggleHidden?() }
                    )

                    // Star — make primary
                    Button {
                        onTogglePrimary?()
                    } label: {
                        Image(systemName: account.isPrimary ? "star.fill" : "star")
                            .font(.system(size: 12))
                            .foregroundStyle(account.isPrimary ? accountColor : .primary.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .background(.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .accessibilityLabel(account.isPrimary ? "Основной счёт" : "Сделать основным")

                    // Share
                    actionButton(
                        icon: "square.and.arrow.up",
                        label: "Поделиться",
                        action: { onShare?() }
                    )

                    // Settings
                    actionButton(
                        icon: "gearshape",
                        label: "Настройки счёта",
                        action: { onEdit?() }
                    )
                }
            }
            .padding(.bottom, 10)

            // Account name
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.7))
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
            LinearGradient(
                colors: [
                    accountColor.opacity(0.08),
                    accountColor.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accountColor.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 4)
    }

    // MARK: - Subviews

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    // MARK: - Computed

    private var monthlyIncome: Int64 {
        var total: Int64 = 0
        for tx in appViewModel.dataStore.transactions {
            if tx.accountId == account.id && tx.type == .income && !tx.isTransfer {
                total += tx.amount
            }
        }
        return total
    }

    private var monthlyExpense: Int64 {
        var total: Int64 = 0
        for tx in appViewModel.dataStore.transactions {
            if tx.accountId == account.id && tx.type == .expense && !tx.isTransfer {
                total += tx.amount
            }
        }
        return total
    }
}
