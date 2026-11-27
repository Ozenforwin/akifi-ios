import SwiftUI
import WidgetKit
import XCTest
@testable import AkifiIOS

/// Renders every family of the «Счёт» and «Быстрая запись» widgets with
/// fixture data into PNGs — light, dark, a tinted approximation and large
/// Dynamic Type. Skipped unless `AKIFI_SNAPSHOT_DIR` is set:
///
///     TEST_RUNNER_AKIFI_SNAPSHOT_DIR=/path xcodebuild test -testLanguage ru -testRegion RU … \
///       -only-testing:AkifiIOSTests/WidgetScreenshotTests
///
/// The views are the ones the extension shows; WidgetKit's own container
/// (corner radius, tinted glass) is imitated: «tinted» renders the
/// `.accented` path (no colour wash, accentable parts) and then tints the
/// whole widget the way iOS 18 / 26 tinted and clear modes do.
@MainActor
final class WidgetScreenshotTests: XCTestCase {

    private var outputDir: URL!

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["AKIFI_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set AKIFI_SNAPSHOT_DIR to render screenshots")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - Fixtures

    private static func account(
        _ name: String, icon: String, color: String, code: String = "RUB", symbol: String = "₽", decimals: Int = 0,
        balance: Int64, income: Int64, expense: Int64, primary: Bool = false, shared: Bool = false, hidden: Bool = false
    ) -> SharedSnapshot.AccountItem {
        SharedSnapshot.AccountItem(
            id: UUID().uuidString.lowercased(), name: name, icon: icon, colorHex: color,
            currencyCode: code, currencySymbol: symbol, currencyDecimals: decimals,
            balance: balance, monthIncome: income, monthExpense: expense,
            isPrimary: primary, isShared: shared, isBalanceHidden: hidden
        )
    }

    private static let card = account("Тинькофф", icon: "💳", color: "#3B82F6", balance: 85_400_00,
                                      income: 120_000_00, expense: 46_380_00, primary: true)
    private static let family = account("Семейный бюджет", icon: "👪", color: "#8B5CF6", balance: 1_234_567_00,
                                        income: 250_000_00, expense: 198_400_00, shared: true)
    private static let usd = account("ByBit", icon: "🪙", color: "#F59E0B", code: "USD", symbol: "$", decimals: 2,
                                     balance: 1_250_75, income: 0, expense: 12_50)
    private static let hidden = account("Наличные", icon: "💵", color: "#10B981", balance: 6_200_00,
                                        income: 2_000_00, expense: 800_00, hidden: true)
    private static let overdrawn = account("Кредитка", icon: "💳", color: "#F43F5E", balance: -12_340_00,
                                           income: 0, expense: 12_340_00)

    private static let repeats: [SharedSnapshot.RepeatItem] = [
        .init(id: "1", isIncome: false, title: "Кофе", icon: "☕️", amountText: "250 ₽", accountName: "Тинькофф",
              url: QuickAddWidgetLinks.open(.expense).absoluteString),
        .init(id: "2", isIncome: false, title: "Пятёрочка", icon: "🛒", amountText: "1 840 ₽", accountName: "Тинькофф",
              url: QuickAddWidgetLinks.open(.expense).absoluteString),
        .init(id: "3", isIncome: true, title: "Зарплата", icon: "💼", amountText: "120 000 ₽", accountName: "Тинькофф",
              url: QuickAddWidgetLinks.open(.income).absoluteString),
    ]

    // MARK: - Rendering

    private enum Look: String, CaseIterable {
        case light, dark, tinted
    }

    /// iPhone 16 widget sizes.
    private static func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: CGSize(width: 158, height: 158)
        case .systemMedium: CGSize(width: 338, height: 158)
        case .systemLarge: CGSize(width: 338, height: 354)
        case .accessoryRectangular: CGSize(width: 160, height: 72)
        case .accessoryInline: CGSize(width: 234, height: 26)
        case .accessoryCircular: CGSize(width: 72, height: 72)
        default: CGSize(width: 158, height: 158)
        }
    }

    private static func isAccessory(_ family: WidgetFamily) -> Bool {
        [.accessoryRectangular, .accessoryInline, .accessoryCircular].contains(family)
    }

    private func render<Content: View, Background: View>(
        _ name: String,
        family: WidgetFamily,
        look: Look,
        dynamicType: DynamicTypeSize = .large,
        @ViewBuilder content: (WidgetRenderingMode) -> Content,
        @ViewBuilder background: (WidgetRenderingMode) -> Background
    ) throws {
        let size = Self.size(family)
        let accessory = Self.isAccessory(family)
        let mode: WidgetRenderingMode = accessory ? .vibrant : (look == .tinted ? .accented : .fullColor)
        let scheme: ColorScheme = (look == .light && !accessory) ? .light : .dark
        let tint = Color(red: 0.62, green: 0.78, blue: 1.0)

        let widget = content(mode)
            .frame(width: size.width, height: size.height)
            .background {
                if accessory {
                    Color.clear
                } else if look == .tinted {
                    Color(white: 0.16)
                } else {
                    background(mode)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: accessory ? 0 : 22, style: .continuous))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, dynamicType)
            .environment(\.locale, Locale(identifier: "ru_RU"))

        let canvas = ZStack {
            wallpaper(accessory: accessory, look: look)
            Group {
                if look == .tinted && !accessory {
                    widget.grayscale(1).colorMultiply(tint)
                } else {
                    widget
                }
            }
            .foregroundStyle(accessory ? Color.white : Color.primary)
        }
        .frame(width: size.width + 40, height: size.height + 40)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, name)
        try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    @ViewBuilder
    private func wallpaper(accessory: Bool, look: Look) -> some View {
        if accessory {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.25), Color(red: 0.30, green: 0.18, blue: 0.35)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            switch look {
            case .light:
                LinearGradient(colors: [Color(red: 0.80, green: 0.88, blue: 0.98), Color(red: 0.95, green: 0.85, blue: 0.90)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case .dark, .tinted:
                LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.18, green: 0.10, blue: 0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private func renderAccount(_ name: String, _ state: AccountWidgetState, family: WidgetFamily, look: Look,
                               dynamicType: DynamicTypeSize = .large) throws {
        try render(name, family: family, look: look, dynamicType: dynamicType) { mode in
            AccountWidgetView(state: state, family: family, renderingMode: mode)
        } background: { mode in
            AccountWidgetBackground(state: state, renderingMode: mode)
        }
    }

    /// «Счёт» as the provider builds it: the account a step (if any) moved
    /// to, with the arrows.
    private func renderPagedAccount(_ name: String, accounts: [SharedSnapshot.AccountItem], showing index: Int,
                                    family: WidgetFamily, look: Look, dynamicType: DynamicTypeSize = .large) throws {
        var snapshot = SharedSnapshot.placeholder
        snapshot.accounts = accounts
        let key = AccountWidgetCarousel.widgetKey(configuredAccountId: accounts[0].id, family: family)
        let content = AccountWidgetCarousel.content(
            snapshot: snapshot, configuredAccountId: accounts[0].id, family: family,
            overrides: index == 0 ? [:] : [key: AccountWidgetOverride(accountId: accounts[index].id, forward: true)]
        )
        XCTAssertEqual(content.state.account?.id, accounts[index].id)
        try render(name, family: family, look: look, dynamicType: dynamicType) { mode in
            AccountWidgetView(state: content.state, family: family, renderingMode: mode, pager: content.pager)
        } background: { mode in
            AccountWidgetBackground(state: content.state, renderingMode: mode)
        }
    }

    private func renderAllAccounts(_ name: String, accounts: [SharedSnapshot.AccountItem]?, family: WidgetFamily, look: Look,
                                   total: Int64 = 1_342_617_00, dynamicType: DynamicTypeSize = .large) throws {
        let snapshot: SharedSnapshot? = accounts.map { accounts in
            var s = SharedSnapshot(
                schemaVersion: SharedSnapshot.currentSchemaVersion, lastUpdated: Date(), baseCurrency: "RUB",
                baseCurrencySymbol: "₽", baseCurrencyDecimals: 0, totalBalance: total, accountCount: accounts.count,
                dailyLimit: nil, dailyLimitBudgetName: nil, dailySpentToday: 0, dailyLimitUtilization: 0,
                currentStreak: 0, nextMilestone: 3, todayIncome: 0, todayExpense: 0, todayNet: 0, netWorth: nil
            )
            s.accounts = accounts
            return s
        }
        let state = AllAccountsWidgetSelection.state(snapshot: snapshot, family: family)
        try render(name, family: family, look: look, dynamicType: dynamicType) { mode in
            AllAccountsWidgetView(state: state, family: family, renderingMode: mode)
        } background: { _ in
            Color(.secondarySystemGroupedBackground)
        }
    }

    private static let fourAccounts = [card, hidden, usd, family]
    private static let nineAccounts: [SharedSnapshot.AccountItem] = [card, hidden, usd, family, overdrawn]
        + [("Сбер", "🏦", "#22C55E", 254_000_00), ("Отпуск", "🏖️", "#06B6D4", 98_500_00),
           ("Вклад", "📈", "#EAB308", 500_000_00), ("Кошелёк", "👛", "#EC4899", 3_150_00)].map {
            account($0.0, icon: $0.1, color: $0.2, balance: $0.3, income: 0, expense: 0)
        }

    private func renderQuickAdd(_ name: String, _ items: [SharedSnapshot.RepeatItem]?, family: WidgetFamily, look: Look,
                                dynamicType: DynamicTypeSize = .large) throws {
        try render(name, family: family, look: look, dynamicType: dynamicType) { mode in
            QuickAddWidgetView(repeatItems: items, family: family, renderingMode: mode)
        } background: { _ in
            Color(.secondarySystemGroupedBackground)
        }
    }

    // MARK: - «Счёт»

    func test_accountWidget_allFamilies() throws {
        let families: [(WidgetFamily, String)] = [
            (.systemSmall, "small"), (.systemMedium, "medium"),
            (.accessoryRectangular, "lock-rect"), (.accessoryInline, "lock-inline"),
        ]
        for (family, label) in families {
            let looks: [Look] = Self.isAccessory(family) ? [.dark] : Look.allCases
            for look in looks {
                try renderAccount("account-\(label)-\(look.rawValue)", .account(Self.card), family: family, look: look)
                try renderAccount("account-\(label)-hidden-\(look.rawValue)", .account(Self.hidden), family: family, look: look)
            }
            try renderAccount("account-\(label)-usd-dark", .account(Self.usd), family: family, look: .dark)
            try renderAccount("account-\(label)-shared-light", .account(Self.family), family: family, look: .light)
            try renderAccount("account-\(label)-signedout-light", .signedOut, family: family, look: Self.isAccessory(family) ? .dark : .light)
        }
        try renderAccount("account-small-overdrawn-light", .account(Self.overdrawn), family: .systemSmall, look: .light)
        try renderAccount("account-small-noaccounts-dark", .noAccounts, family: .systemSmall, look: .dark)
        try renderAccount("account-small-xxxl-light", .account(Self.card), family: .systemSmall, look: .light, dynamicType: .accessibility3)
        try renderAccount("account-medium-xxxl-dark", .account(Self.family), family: .systemMedium, look: .dark, dynamicType: .accessibility3)
    }

    // MARK: - «Счёт» arrows

    func test_accountWidget_arrows() throws {
        for family in [WidgetFamily.systemSmall, .systemMedium] {
            let label = family == .systemSmall ? "small" : "medium"
            for look in Look.allCases {
                try renderPagedAccount("account-arrows-\(label)-\(look.rawValue)", accounts: Self.fourAccounts, showing: 0,
                                       family: family, look: look)
            }
            // After «›»: the USD account, third of four.
            try renderPagedAccount("account-arrows-\(label)-stepped-light", accounts: Self.fourAccounts, showing: 2,
                                   family: family, look: .light)
            try renderPagedAccount("account-arrows-\(label)-hidden-dark", accounts: Self.fourAccounts, showing: 1,
                                   family: family, look: .dark)
            // Nine accounts: «3/9» instead of dots.
            try renderPagedAccount("account-arrows-\(label)-many-light", accounts: Self.nineAccounts, showing: 2,
                                   family: family, look: .light)
            try renderPagedAccount("account-arrows-\(label)-two-dark", accounts: [Self.card, Self.usd], showing: 1,
                                   family: family, look: .dark)
            // One account: no arrows (the original layout).
            try renderPagedAccount("account-arrows-\(label)-single-light", accounts: [Self.card], showing: 0,
                                   family: family, look: .light)
        }
        try renderPagedAccount("account-arrows-small-xxxl-light", accounts: Self.fourAccounts, showing: 3,
                               family: .systemSmall, look: .light, dynamicType: .accessibility3)
        try renderPagedAccount("account-arrows-medium-xxxl-dark", accounts: Self.fourAccounts, showing: 3,
                               family: .systemMedium, look: .dark, dynamicType: .accessibility3)
    }

    // MARK: - «Все счета»

    func test_allAccountsWidget() throws {
        for family in [WidgetFamily.systemMedium, .systemLarge] {
            let label = family == .systemMedium ? "medium" : "large"
            for look in Look.allCases {
                try renderAllAccounts("accounts-\(label)-\(look.rawValue)", accounts: Self.fourAccounts.filter { !$0.isBalanceHidden }
                                      + [Self.overdrawn], family: family, look: look)
            }
            // «Наличные» hidden on Home: «••••», and the total too.
            try renderAllAccounts("accounts-\(label)-hidden-light", accounts: Self.fourAccounts, family: family, look: .light)
            try renderAllAccounts("accounts-\(label)-one-dark", accounts: [Self.card], family: family, look: .dark, total: 85_400_00)
            try renderAllAccounts("accounts-\(label)-many-light", accounts: Self.nineAccounts.filter { !$0.isBalanceHidden }
                                  + [Self.account("Ещё один", icon: "💼", color: "#64748B", balance: 1_000_00, income: 0, expense: 0)],
                                  family: family, look: .light)
            try renderAllAccounts("accounts-\(label)-signedout-dark", accounts: nil, family: family, look: .dark)
            try renderAllAccounts("accounts-\(label)-noaccounts-light", accounts: [], family: family, look: .light)
            try renderAllAccounts("accounts-\(label)-xxxl-dark", accounts: Self.nineAccounts, family: family, look: .dark,
                                  dynamicType: .accessibility3)
        }
    }

    // MARK: - «Быстрая запись»

    func test_quickAddWidget_allFamilies() throws {
        for look in Look.allCases {
            try renderQuickAdd("quickadd-small-\(look.rawValue)", Self.repeats, family: .systemSmall, look: look)
            try renderQuickAdd("quickadd-medium-\(look.rawValue)", Self.repeats, family: .systemMedium, look: look)
        }
        try renderQuickAdd("quickadd-medium-norepeats-light", [], family: .systemMedium, look: .light)
        try renderQuickAdd("quickadd-medium-signedout-dark", nil, family: .systemMedium, look: .dark)
        try renderQuickAdd("quickadd-lock-circular-dark", nil, family: .accessoryCircular, look: .dark)
        try renderQuickAdd("quickadd-small-xxxl-light", Self.repeats, family: .systemSmall, look: .light, dynamicType: .accessibility3)
        try renderQuickAdd("quickadd-medium-xxxl-dark", Self.repeats, family: .systemMedium, look: .dark, dynamicType: .accessibility3)
    }
}
