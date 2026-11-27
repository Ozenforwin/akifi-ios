import SwiftUI
import WidgetKit

// «Счёт» widget views. Shared with the app so tests can render every family
// to PNG; the extension wraps them in `AccountWidget` (AkifiWidget/).
// Widgets are content (liquid-glass.md §1): no glass here — iOS 26 puts
// its own glass around a tinted / clear widget.

/// What one «Счёт» entry shows.
enum AccountWidgetState: Equatable, Sendable {
    case account(SharedSnapshot.AccountItem)
    /// A v2 snapshot, but the user has no money accounts.
    case noAccounts
    /// No usable snapshot: signed out, fresh install, a 1.5.x file.
    case signedOut

    /// The configured account, else the primary one (a deleted account
    /// never leaves the widget blank while others exist).
    static func resolve(snapshot: SharedSnapshot?, accountId: String?) -> AccountWidgetState {
        guard let snapshot, snapshot.accounts != nil else { return .signedOut }
        guard let item = AccountWidgetSelection.resolve(id: accountId, in: snapshot) else { return .noAccounts }
        return .account(item)
    }

    var account: SharedSnapshot.AccountItem? {
        if case .account(let item) = self { return item }
        return nil
    }
}

/// Deep links of the «Счёт» widget — every quick button opens the sheet
/// with THIS account preselected.
enum AccountWidgetLinks {
    static let home = URL(string: "akifi://home")!

    static func quickEntry(_ mode: QuickEntryLaunchMode, accountId: String) -> URL {
        QuickEntryLaunchLink(mode: mode, source: .widget, accountId: accountId).url
    }
}

// MARK: - Background

/// The container background: the account's colour as a light wash in full
/// colour (like its Home card), the plain card colour otherwise — tinted /
/// clear modes replace it with the system's own material anyway.
struct AccountWidgetBackground: View {
    let state: AccountWidgetState
    let renderingMode: WidgetRenderingMode

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            if renderingMode == .fullColor, let account = state.account {
                let tint = WidgetPalette.color(hex: account.colorHex) ?? WidgetPalette.accent
                LinearGradient(
                    colors: [tint.opacity(WidgetPalette.wash.start), tint.opacity(WidgetPalette.wash.end)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

// MARK: - Entry view

struct AccountWidgetView: View {
    let state: AccountWidgetState
    let family: WidgetFamily
    let renderingMode: WidgetRenderingMode

    var body: some View {
        switch state {
        case .account(let account):
            switch family {
            case .accessoryInline:
                AccountInlineView(account: account)
            case .accessoryRectangular:
                AccountRectangularView(account: account)
            case .systemMedium:
                AccountMediumView(account: account, renderingMode: renderingMode)
            default:
                AccountSmallView(account: account, renderingMode: renderingMode)
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

/// The account's emoji on a tile of its colour.
private struct AccountIconTile: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        let tint = WidgetPalette.color(hex: account.colorHex) ?? WidgetPalette.accent
        Text(verbatim: account.icon)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(
                renderingMode == .fullColor ? tint.opacity(0.18) : Color.primary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// ★ primary, two people for a shared account.
private struct AccountBadges: View {
    let account: SharedSnapshot.AccountItem

    var body: some View {
        HStack(spacing: 4) {
            if account.isShared {
                Image(systemName: "person.2.fill")
                    .accessibilityLabel(Text(LocalizedStringResource("widget.account.shared", defaultValue: "Совместный")))
            }
            if account.isPrimary {
                Image(systemName: "star.fill")
                    .accessibilityLabel(Text(LocalizedStringResource("widget.account.primary", defaultValue: "Основной")))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// «↗ +12 000 ₽» / «↙ −8 450 ₽».
private struct AccountFlowLabel: View {
    let account: SharedSnapshot.AccountItem
    let isIncome: Bool
    let renderingMode: WidgetRenderingMode

    var body: some View {
        Label {
            Text(verbatim: isIncome ? WidgetMoney.income(account) : WidgetMoney.expense(account))
                .privacySensitive()
        } icon: {
            Image(systemName: isIncome ? "arrow.up.right" : "arrow.down.left")
        }
        .labelStyle(.compactFlow)
        .foregroundStyle(renderingMode == .fullColor ? (isIncome ? WidgetPalette.income : WidgetPalette.expense) : Color.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isIncome
            ? LocalizedStringResource("widget.account.monthIncome", defaultValue: "Доход за месяц")
            : LocalizedStringResource("widget.account.monthExpense", defaultValue: "Расход за месяц")))
        .accessibilityValue(Text(verbatim: account.isBalanceHidden ? "" : (isIncome ? WidgetMoney.income(account) : WidgetMoney.expense(account))))
    }
}

private struct CompactFlowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactFlowLabelStyle {
    static var compactFlow: CompactFlowLabelStyle { CompactFlowLabelStyle() }
}

/// The balance — the widget's one accented element.
private struct AccountBalanceText: View {
    let account: SharedSnapshot.AccountItem
    let font: Font
    let renderingMode: WidgetRenderingMode

    var body: some View {
        Text(verbatim: WidgetMoney.balance(account))
            .font(font)
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .foregroundStyle(renderingMode == .fullColor && account.balance < 0 && !account.isBalanceHidden
                             ? WidgetPalette.expense : Color.primary)
            .privacySensitive()
            .widgetAccentable()
            .accessibilityLabel(Text(LocalizedStringResource("widget.account.balance", defaultValue: "Баланс")))
            .accessibilityValue(account.isBalanceHidden
                ? Text(LocalizedStringResource("widget.account.balanceHidden", defaultValue: "Баланс скрыт"))
                : Text(verbatim: WidgetMoney.balance(account)))
    }
}

// MARK: - Families

/// `.systemSmall`: icon, name, balance, this month in / out. Tap → Home.
struct AccountSmallView: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                AccountIconTile(account: account, renderingMode: renderingMode)
                Spacer(minLength: 4)
                AccountBadges(account: account)
            }
            Spacer(minLength: 6)
            Text(verbatim: account.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            AccountBalanceText(account: account, font: .title2, renderingMode: renderingMode)
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 2) {
                AccountFlowLabel(account: account, isIncome: true, renderingMode: renderingMode)
                AccountFlowLabel(account: account, isIncome: false, renderingMode: renderingMode)
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .widgetURL(AccountWidgetLinks.home)
    }
}

/// `.systemMedium`: the same + «Расход», «Доход», «Голосом» that open
/// quick entry on this account.
struct AccountMediumView: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        AccountIconTile(account: account, renderingMode: renderingMode)
                        Text(verbatim: account.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        AccountBadges(account: account)
                    }
                    AccountBalanceText(account: account, font: .title, renderingMode: renderingMode)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    AccountFlowLabel(account: account, isIncome: true, renderingMode: renderingMode)
                    AccountFlowLabel(account: account, isIncome: false, renderingMode: renderingMode)
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                quickButton(.expense, systemImage: "minus", color: WidgetPalette.expense,
                            title: LocalizedStringResource("quickEntry.mode.expense", defaultValue: "Расход"))
                quickButton(.income, systemImage: "plus", color: WidgetPalette.income,
                            title: LocalizedStringResource("quickEntry.mode.income", defaultValue: "Доход"))
                quickButton(.voice, systemImage: "mic.fill", color: WidgetPalette.accent,
                            title: LocalizedStringResource("quickEntry.mode.voice", defaultValue: "Голосом"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetURL(AccountWidgetLinks.home)
    }

    private func quickButton(_ mode: QuickEntryLaunchMode, systemImage: String, color: Color, title: LocalizedStringResource) -> some View {
        Link(destination: AccountWidgetLinks.quickEntry(mode, accountId: account.id)) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .fontWeight(.bold)
                    .foregroundStyle(renderingMode == .fullColor ? color : Color.primary)
                    .widgetAccentable()
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(WidgetChipFill.color(renderingMode), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityHint(Text(verbatim: String(
            format: String(localized: "widget.account.button.hint", defaultValue: "Быстрый ввод на счёт %@"),
            account.name
        )))
    }
}

/// Lock Screen `.accessoryRectangular`: name, balance, month in / out.
struct AccountRectangularView: View {
    let account: SharedSnapshot.AccountItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(account.icon) \(account.name)")
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            AccountBalanceText(account: account, font: .title3, renderingMode: .vibrant)
            HStack(spacing: 6) {
                AccountFlowLabel(account: account, isIncome: true, renderingMode: .vibrant)
                AccountFlowLabel(account: account, isIncome: false, renderingMode: .vibrant)
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .widgetURL(AccountWidgetLinks.home)
    }
}

/// Lock Screen `.accessoryInline`: «💳 Тинькофф · 85 400 ₽», shortened to
/// the balance when it doesn't fit.
struct AccountInlineView: View {
    let account: SharedSnapshot.AccountItem

    var body: some View {
        ViewThatFits {
            Text(verbatim: "\(account.icon) \(account.name) · \(WidgetMoney.balance(account))")
            Text(verbatim: "\(account.icon) \(WidgetMoney.balance(account))")
        }
        .privacySensitive()
        .widgetURL(AccountWidgetLinks.home)
    }
}

// MARK: - Shared bits

/// Fill of a widget button: a neutral chip in full colour (the sheet's
/// chips — liquid-glass.md §8), a light plate when the system tints.
enum WidgetChipFill {
    static func color(_ renderingMode: WidgetRenderingMode) -> Color {
        renderingMode == .fullColor ? Color(.tertiarySystemFill) : Color.primary.opacity(0.14)
    }
}

/// «Откройте Akifi» / «Нет счетов» in every family.
struct WidgetMessageView: View {
    let family: WidgetFamily
    let systemImage: String
    let title: String
    let subtitle: String
    var url: URL = AccountWidgetLinks.home

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(verbatim: title)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(verbatim: "Akifi")
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    .font(.headline)
                    .widgetAccentable()
                    Text(verbatim: title)
                        .font(.caption)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(WidgetPalette.accent)
                        .widgetAccentable()
                    Spacer(minLength: 0)
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
        }
        .accessibilityElement(children: .combine)
        .widgetURL(url)
    }
}
