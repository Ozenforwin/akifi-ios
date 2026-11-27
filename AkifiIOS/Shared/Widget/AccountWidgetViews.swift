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

/// Deep links of the «Счёт» and «Все счета» widgets — every quick button
/// opens the sheet with THIS account preselected; a tap on an account opens
/// Home on it.
enum AccountWidgetLinks {
    static let home = URL(string: "akifi://home")!

    /// `akifi://account?id=<uuid>` — parsed by `DeepLink.parse` (app).
    static let accountHost = "account"
    static let accountIdQueryItem = "id"

    static func quickEntry(_ mode: QuickEntryLaunchMode, accountId: String) -> URL {
        QuickEntryLaunchLink(mode: mode, source: .widget, accountId: accountId).url
    }

    /// Opens the app on Home with this account selected in the carousel.
    /// Account ids are UUIDs; anything else (never a DB id) opens Home.
    static func account(_ id: String) -> URL {
        guard let uuid = UUID(uuidString: id) else { return home }
        var components = URLComponents()
        components.scheme = "akifi"
        components.host = accountHost
        components.queryItems = [URLQueryItem(name: accountIdQueryItem, value: uuid.uuidString.lowercased())]
        return components.url ?? home
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
    /// ‹ › and the page dots (small / medium with more than one account).
    var pager: AccountWidgetPager? = nil

    var body: some View {
        switch state {
        case .account(let account):
            switch family {
            case .accessoryInline:
                AccountInlineView(account: account)
            case .accessoryRectangular:
                AccountRectangularView(account: account)
            case .systemMedium:
                AccountMediumView(account: account, renderingMode: renderingMode, pager: pager)
            default:
                AccountSmallView(account: account, renderingMode: renderingMode, pager: pager)
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
struct AccountIconTile: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode
    @ScaledMetric private var size: CGFloat

    init(account: SharedSnapshot.AccountItem, renderingMode: WidgetRenderingMode, size: CGFloat = 30) {
        self.account = account
        self.renderingMode = renderingMode
        self._size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

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
struct AccountBadges: View {
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
            .contentTransition(.numericText())
            .privacySensitive()
            .widgetAccentable()
            .accessibilityLabel(Text(LocalizedStringResource("widget.account.balance", defaultValue: "Баланс")))
            .accessibilityValue(account.isBalanceHidden
                ? Text(LocalizedStringResource("widget.account.balanceHidden", defaultValue: "Баланс скрыт"))
                : Text(verbatim: WidgetMoney.balance(account)))
    }
}

// MARK: - Families

/// `.systemSmall`: icon, name, balance, this month in / out; ‹ › in the
/// top-right corner when there are other accounts. Tap → Home on this
/// account.
struct AccountSmallView: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode
    var pager: AccountWidgetPager? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                AccountIconTile(account: account, renderingMode: renderingMode)
                    .accountSwitchTransition(account: account, pager: pager)
                Spacer(minLength: 4)
                if let pager {
                    AccountWidgetPagerControl(pager: pager, renderingMode: renderingMode, hitWidth: 32)
                } else {
                    AccountBadges(account: account)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: account.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if pager != nil {
                        // The arrows took the top-right corner.
                        AccountBadges(account: account)
                    }
                }
                AccountBalanceText(account: account, font: .title2, renderingMode: renderingMode)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    AccountFlowLabel(account: account, isIncome: true, renderingMode: renderingMode)
                    AccountFlowLabel(account: account, isIncome: false, renderingMode: renderingMode)
                }
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
            }
            .accountSwitchTransition(account: account, pager: pager)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .widgetURL(AccountWidgetLinks.account(account.id))
    }
}

/// `.systemMedium`: the same + «Расход», «Доход», «Голосом» that open
/// quick entry on this account; ‹ › around the page dots on the header
/// row when there are other accounts.
struct AccountMediumView: View {
    let account: SharedSnapshot.AccountItem
    let renderingMode: WidgetRenderingMode
    var pager: AccountWidgetPager? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        AccountIconTile(account: account, renderingMode: renderingMode)
                        Text(verbatim: account.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        AccountBadges(account: account)
                    }
                    .accountSwitchTransition(account: account, pager: pager)
                    Spacer(minLength: 4)
                    if let pager {
                        AccountWidgetPagerControl(pager: pager, renderingMode: renderingMode, hitWidth: 40)
                    }
                }
                HStack(alignment: .center, spacing: 10) {
                    AccountBalanceText(account: account, font: .title, renderingMode: renderingMode)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        AccountFlowLabel(account: account, isIncome: true, renderingMode: renderingMode)
                        AccountFlowLabel(account: account, isIncome: false, renderingMode: renderingMode)
                    }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }
                .accountSwitchTransition(account: account, pager: pager)
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
        .widgetURL(AccountWidgetLinks.account(account.id))
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
        .widgetURL(AccountWidgetLinks.account(account.id))
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
        .widgetURL(AccountWidgetLinks.account(account.id))
    }
}

// MARK: - Arrows

/// «‹ ••●• ›» — interactive buttons (`AccountWidgetStepIntent`, run by the
/// system without opening the app) around the page indicator: dots up to
/// `AccountWidgetPager.maxDots` accounts when they fit, «3/9» otherwise.
struct AccountWidgetPagerControl: View {
    let pager: AccountWidgetPager
    let renderingMode: WidgetRenderingMode
    /// Tap width of one arrow; the height is the header row's 32 pt.
    let hitWidth: CGFloat

    static let hitHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            arrow(forward: false)
            indicator
            arrow(forward: true)
        }
        // Offered the row's free width before the spacer, so the dots get
        // every point they can use before falling back to «3/9».
        .layoutPriority(1)
    }

    private func arrow(forward: Bool) -> some View {
        Button(intent: AccountWidgetStepIntent(pager: pager, forward: forward)) {
            Image(systemName: forward ? "chevron.forward" : "chevron.backward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(WidgetChipFill.color(renderingMode), in: Circle())
                .frame(width: hitWidth, height: Self.hitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(forward
            ? LocalizedStringResource("widget.account.next", defaultValue: "Следующий счёт")
            : LocalizedStringResource("widget.account.previous", defaultValue: "Предыдущий счёт")))
        .accessibilityHint(Text(verbatim: forward ? pager.nextName : pager.previousName))
    }

    private var indicator: some View {
        Group {
            if pager.showsDots {
                ViewThatFits(in: .horizontal) {
                    dots
                    counter
                }
            } else {
                counter
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource("widget.account.page.label", defaultValue: "Счёт")))
        .accessibilityValue(Text(verbatim: String(
            format: String(localized: "widget.account.page.value", defaultValue: "%1$@, %2$lld из %3$lld"),
            pager.currentName,
            pager.position + 1,
            pager.count
        )))
    }

    private var dots: some View {
        HStack(spacing: 3) {
            ForEach(Array(pager.pages.enumerated()), id: \.offset) { index, page in
                let isCurrent = index == pager.position
                Capsule()
                    .fill(dotColor(page, isCurrent: isCurrent))
                    .frame(width: isCurrent ? 10 : 5, height: 5)
            }
        }
        .padding(.horizontal, 2)
        .fixedSize()
    }

    /// The shown account's dot in its colour (full colour), the others grey;
    /// tinted / clear: the shown one primary (accentable), the rest faint.
    private func dotColor(_ page: AccountWidgetPager.Page, isCurrent: Bool) -> Color {
        guard isCurrent else {
            return renderingMode == .fullColor ? Color(.tertiaryLabel) : Color.primary.opacity(0.3)
        }
        guard renderingMode == .fullColor else { return Color.primary }
        return WidgetPalette.color(hex: page.colorHex) ?? WidgetPalette.accent
    }

    private var counter: some View {
        Text(verbatim: pager.counterText)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 2)
    }
}

private extension View {
    /// The account's own content is replaced, not morphed, when the arrows
    /// switch accounts: the new one slides in from the side the user went
    /// to (trailing after «›», leading after «‹») while the old one fades
    /// in place. Checked on the iOS 26.5 Home Screen (2026-11-28):
    /// - the outgoing view animates with the transition of the render it
    ///   came from, so a symmetric `.push` sends it the wrong way on the
    ///   first tap after a change of direction — hence the fade-only
    ///   removal;
    /// - `.push(from:)` as the insertion of an `.asymmetric` transition is
    ///   played mirrored by WidgetKit (it came in from the opposite edge);
    ///   `.move(edge:)` + `.opacity` is played as written.
    /// Without animation it is a plain swap.
    func accountSwitchTransition(account: SharedSnapshot.AccountItem, pager: AccountWidgetPager?) -> some View {
        let edge: Edge = (pager?.forward ?? true) ? .trailing : .leading
        return self
            .id(account.id)
            .transition(.asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .opacity))
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
