import SwiftUI
import WidgetKit

// «Все счета» widget (1.6.0): every money account with its balance; a tap
// on one opens Home on it. Shared with the app so tests can render it to
// PNG; the extension wraps it in `AllAccountsWidget` (AkifiWidget/).
// Content, not glass (liquid-glass.md §11).

/// What one «Все счета» entry shows.
enum AllAccountsWidgetState: Equatable, Sendable {
    case accounts(AllAccountsWidgetContent)
    /// A v2 snapshot, but the user has no money accounts.
    case noAccounts
    /// No usable snapshot: signed out, fresh install, a 1.5.x file.
    case signedOut
}

/// The accounts a «Все счета» widget lists and its header total.
struct AllAccountsWidgetContent: Equatable, Sendable {
    /// The first accounts in the app's order (= the Home carousel).
    let items: [SharedSnapshot.AccountItem]
    /// Accounts that didn't fit — the «+N ещё» footer.
    let moreCount: Int
    /// The snapshot's base-currency total (the «Баланс» widget's number).
    let total: Int64
    let totalSymbol: String
    let totalDecimals: Int
    /// Some account's balance is hidden on Home (the eye), so the total
    /// would give it away.
    let isTotalHidden: Bool

    var totalText: String {
        isTotalHidden ? WidgetMoney.hidden : WidgetMoney.format(total, symbol: totalSymbol, decimals: totalDecimals)
    }
}

/// Which accounts a «Все счета» widget shows. Pure (tested).
enum AllAccountsWidgetSelection {
    /// Medium: a 2 × 2 grid. Large: 8 rows under the total.
    static func limit(for family: WidgetFamily) -> Int {
        family == .systemLarge ? 8 : 4
    }

    /// The total reveals what a hidden balance hides (the other balances
    /// are on screen), so one hidden account hides the total too.
    static func isTotalHidden(_ accounts: [SharedSnapshot.AccountItem]) -> Bool {
        accounts.contains(where: \.isBalanceHidden)
    }

    static func state(snapshot: SharedSnapshot?, family: WidgetFamily) -> AllAccountsWidgetState {
        guard let snapshot, let accounts = snapshot.accounts else { return .signedOut }
        guard !accounts.isEmpty else { return .noAccounts }
        let limit = limit(for: family)
        return .accounts(AllAccountsWidgetContent(
            items: Array(accounts.prefix(limit)),
            moreCount: max(0, accounts.count - limit),
            total: snapshot.totalBalance,
            totalSymbol: snapshot.baseCurrencySymbol,
            totalDecimals: snapshot.baseCurrencyDecimals,
            isTotalHidden: isTotalHidden(accounts)
        ))
    }
}

// MARK: - Entry view

struct AllAccountsWidgetView: View {
    let state: AllAccountsWidgetState
    let family: WidgetFamily
    let renderingMode: WidgetRenderingMode

    var body: some View {
        switch state {
        case .accounts(let content):
            if family == .systemLarge {
                AllAccountsLargeView(content: content, renderingMode: renderingMode)
            } else {
                AllAccountsMediumView(content: content, renderingMode: renderingMode)
            }
        case .noAccounts:
            WidgetMessageView(
                family: family,
                systemImage: "creditcard",
                title: String(localized: "widget.account.noAccounts.title", defaultValue: "Нет счетов"),
                subtitle: String(localized: "widget.account.noAccounts.subtitle", defaultValue: "Добавьте счёт в Akifi")
            )
        case .signedOut:
            WidgetMessageView(
                family: family,
                systemImage: "creditcard",
                title: String(localized: "widget.empty.title", defaultValue: "Откройте Akifi"),
                subtitle: String(localized: "widget.empty.subtitle", defaultValue: "Войдите, чтобы здесь появились ваши данные")
            )
        }
    }
}

// MARK: - Pieces

/// One account's balance in ITS OWN currency (ADR-001: never converted or
/// summed here); red when negative in full colour, «••••» when hidden.
private struct AllAccountsBalanceText: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode

    var body: some View {
        Text(verbatim: WidgetMoney.balance(account))
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(renderingMode == .fullColor && account.balance < 0 && !account.isBalanceHidden
                             ? WidgetPalette.expense : Color.primary)
            .contentTransition(.numericText())
            .privacySensitive()
            .widgetAccentable()
    }
}

/// Name and ★ / shared badges on one line.
private struct AllAccountsNameLine: View {
    let account: SharedSnapshot.AccountItem

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: account.name)
                .lineLimit(1)
            AccountBadges(account: account)
        }
    }
}

/// A tappable account: `Link` to Home on it, VoiceOver reads «Тинькофф,
/// Основной — 85 400 ₽».
private struct AllAccountsLink<Content: View>: View {
    let account: SharedSnapshot.AccountItem
    @ViewBuilder let content: Content

    var body: some View {
        Link(destination: AccountWidgetLinks.account(account.id)) {
            content
                .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AllAccountsAccessibility.label(account)))
        .accessibilityValue(account.isBalanceHidden
            ? Text(LocalizedStringResource("widget.account.balanceHidden", defaultValue: "Баланс скрыт"))
            : Text(verbatim: WidgetMoney.balance(account)))
        .accessibilityHint(Text(LocalizedStringResource("widget.accounts.open.hint", defaultValue: "Открыть счёт в Akifi")))
    }
}

enum AllAccountsAccessibility {
    static func label(_ account: SharedSnapshot.AccountItem) -> String {
        var parts = [account.name]
        if account.isPrimary {
            parts.append(String(localized: "widget.account.primary", defaultValue: "Основной"))
        }
        if account.isShared {
            parts.append(String(localized: "widget.account.shared", defaultValue: "Совместный"))
        }
        return parts.joined(separator: ", ")
    }
}

/// «+3 ещё» — opens Home, where the carousel has every account.
private struct AllAccountsMoreFooter: View {
    let count: Int

    var body: some View {
        Link(destination: AccountWidgetLinks.home) {
            HStack(spacing: 2) {
                Text(verbatim: String(
                    format: String(localized: "widget.accounts.more", defaultValue: "+%lld ещё"),
                    count
                ))
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .accessibilityHint(Text(LocalizedStringResource("widget.accounts.more.hint", defaultValue: "Все счета в Akifi")))
    }
}

// MARK: - Families

/// `.systemMedium`: up to four accounts in a 2 × 2 grid, «+N ещё» below.
struct AllAccountsMediumView: View {
    let content: AllAccountsWidgetContent
    let renderingMode: WidgetRenderingMode

    private var rows: [[SharedSnapshot.AccountItem]] {
        stride(from: 0, to: content.items.count, by: 2).map { Array(content.items[$0..<min($0 + 2, content.items.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(row) { account in
                        cell(account)
                    }
                    if row.count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                // Rows share the height; one or two accounts sit centred.
                .frame(maxHeight: .infinity)
            }
            if content.moreCount > 0 {
                AllAccountsMoreFooter(count: content.moreCount)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetURL(AccountWidgetLinks.home)
    }

    private func cell(_ account: SharedSnapshot.AccountItem) -> some View {
        AllAccountsLink(account: account) {
            HStack(spacing: 8) {
                AccountIconTile(account: account, renderingMode: renderingMode, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    AllAccountsNameLine(account: account)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    AllAccountsBalanceText(account: account, renderingMode: renderingMode)
                        .font(.callout)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// `.systemLarge`: the base-currency total, then up to eight rows.
struct AllAccountsLargeView: View {
    let content: AllAccountsWidgetContent
    let renderingMode: WidgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.top, 8)
                .padding(.bottom, 2)
            VStack(spacing: 0) {
                ForEach(content.items) { account in
                    row(account)
                        .frame(minHeight: 28, maxHeight: 38)
                }
            }
            Spacer(minLength: 0)
            if content.moreCount > 0 {
                AllAccountsMoreFooter(count: content.moreCount)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetURL(AccountWidgetLinks.home)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringResource("widget.accounts.total", defaultValue: "Всего на счетах"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: content.totalText)
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(renderingMode == .fullColor && content.total < 0 && !content.isTotalHidden
                                 ? WidgetPalette.expense : Color.primary)
                .contentTransition(.numericText())
                .privacySensitive()
                .widgetAccentable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource("widget.accounts.total", defaultValue: "Всего на счетах")))
        .accessibilityValue(content.isTotalHidden
            ? Text(LocalizedStringResource("widget.account.balanceHidden", defaultValue: "Баланс скрыт"))
            : Text(verbatim: content.totalText))
    }

    private func row(_ account: SharedSnapshot.AccountItem) -> some View {
        AllAccountsLink(account: account) {
            HStack(spacing: 10) {
                AccountIconTile(account: account, renderingMode: renderingMode, size: 26)
                AllAccountsNameLine(account: account)
                    .font(.subheadline)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                AllAccountsBalanceText(account: account, renderingMode: renderingMode)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
