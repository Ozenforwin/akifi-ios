import Foundation

// MARK: - App Tab

/// Top-level destinations of the signed-in UI — the `TabView` selection.
///
/// The bar (1.6): Главная · Операции · Аналитика · Бюджеты, plus the
/// Assistant as the separate trailing round tab (`role: .search`).
/// `journal` is not in the bar — it wasn't before 1.6 either: no tab item,
/// deep link, push or assistant action selects it (`NavigationTarget.journal`
/// is a no-op). The case stays so the type keeps its meaning for callers and
/// a stray selection is folded back into the bar by `resolvedForTabBar`.
enum AppTab: Int, CaseIterable, Sendable {
    case home = 0
    case transactions = 1
    case analytics = 2
    case journal = 3
    case budgets = 4
    case assistant = 5

    /// Screen name sent with the screen-view analytics event.
    var screenName: String {
        switch self {
        case .home: "Home"
        case .transactions: "Transactions"
        case .analytics: "Analytics"
        case .journal: "Journal"
        case .budgets: "Budgets"
        case .assistant: "Assistant"
        }
    }

    /// Regular tabs, in bar order.
    static let barTabs: [AppTab] = [.home, .transactions, .analytics, .budgets]

    /// Every tab that has an item in the tab bar (regular + the trailing
    /// Assistant tab).
    static let tabBarTabs: [AppTab] = barTabs + [.assistant]

    var isInTabBar: Bool { Self.tabBarTabs.contains(self) }

    /// The tab actually shown for a requested selection: tabs without a bar
    /// item (Journal) fall back to Home instead of leaving the `TabView` with
    /// nothing selected.
    var resolvedForTabBar: AppTab { isInTabBar ? self : .home }

    /// Localized tab title (also the VoiceOver label of the tab item).
    var title: String {
        switch self {
        case .home: String(localized: "tab.home")
        case .transactions: String(localized: "tab.transactions")
        case .analytics: String(localized: "tab.analytics")
        case .journal: String(localized: "tab.journal")
        case .budgets: String(localized: "tab.budgets")
        case .assistant: String(localized: "tab.assistant")
        }
    }

    /// SF Symbol of the tab item — outline; the system fills the selected one.
    var systemImage: String {
        switch self {
        case .home: "house"
        case .transactions: "arrow.left.arrow.right"
        case .analytics: "chart.bar"
        case .journal: "book"
        case .budgets: "wallet.bifold"
        case .assistant: "sparkles"
        }
    }

    /// Whether the floating «+» button is shown over this tab. Not on the
    /// Assistant (it has its own composer), never while a keyboard is up.
    static func showsAddButton(on tab: AppTab, keyboardVisible: Bool) -> Bool {
        tab != .assistant && !keyboardVisible
    }

    /// Tab named by a push notification's `tab` payload (AppDelegate).
    init?(pushTarget: String) {
        switch pushTarget {
        case "home": self = .home
        case "transactions": self = .transactions
        case "budget", "budgets": self = .budgets
        case "analytics": self = .analytics
        default: return nil
        }
    }
}

// MARK: - Assistant navigation

/// What `MainTabView` does with a navigation request coming from the
/// assistant: switch tab or open an add form.
enum AssistantRoute: Equatable, Sendable {
    case selectTab(AppTab)
    case addExpense
    case addIncome
    /// Nothing to do (Journal has no bar tab — unchanged since before 1.6).
    case none

    init(_ target: NavigationTarget) {
        switch target {
        case .transactions: self = .selectTab(.transactions)
        case .budgets, .savings: self = .selectTab(.budgets)
        case .journal: self = .none
        case .addExpense: self = .addExpense
        case .addIncome: self = .addIncome
        }
    }
}
