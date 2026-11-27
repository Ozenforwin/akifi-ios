#if DEBUG
import SwiftUI
import UIKit

// DEBUG-only additions to the screenshot harness (`UIHarness.swift`):
//
// 1. `UIHarnessStubProtocol` answers every request to the Supabase host
//    from local fixtures — the harness makes no network calls at all, and
//    screens backed by their own repositories (savings, deposits,
//    challenges, achievements, categories) render populated.
// 2. `-AkifiUIHarnessScreen <name>` opens one screen directly: pushed
//    screens on a navigation stack with Settings as the root (so the back
//    button and inline title look as in the app), sheets presented over
//    Settings, overlays over the tabs. Names: `UIHarnessScreen.allCases`.
//
// Compiled out of Release together with the rest of `Debug/`.

// MARK: - Setup

enum UIHarnessScreens {
    /// Called by `UIHarness.makeAppViewModel()` before anything loads.
    @MainActor
    static func prepare(_ app: AppViewModel) {
        URLProtocol.registerClass(UIHarnessStubProtocol.self)
        let journal = app.journalViewModel
        journal.fetchPage = { _, after in
            after == nil ? UIHarnessFixtures.notes() : []
        }
        journal.fetchAllTags = { UIHarnessFixtures.journalTags }
    }
}

// MARK: - Network stub

/// Answers Supabase REST requests from `UIHarnessFixtures`; everything
/// else on the Supabase host (auth, functions, storage) gets an error.
/// Mirrors PostgREST closely enough for `SupabasePaging`: `eq.` filters,
/// `offset` / `limit`, `Content-Range` with the total count, and
/// `vnd.pgrst.object` for `.single()`.
final class UIHarnessStubProtocol: URLProtocol, @unchecked Sendable {
    private static let supabaseHost = URL(string: AppConstants.supabaseURL)?.host

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host, let supabaseHost else { return false }
        return host == supabaseHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = UIHarnessFixtures.reply(to: request)
        if let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                          httpVersion: "HTTP/1.1", headerFields: reply.headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

enum UIHarnessFixtures {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    /// The stub's answer to `request`.
    static func reply(to request: URLRequest) -> Reply {
        let json = ["Content-Type": "application/json"]
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return Reply(status: 400, headers: json, body: Data("{}".utf8)) }

        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "rest", parts[1] == "v1" else {
            // Auth, edge functions, storage: no server in the harness.
            return Reply(status: 503, headers: json,
                         body: Data(#"{"error":"UI harness: no server"}"#.utf8))
        }
        // Writes and RPCs succeed without doing anything.
        guard (request.httpMethod ?? "GET") == "GET", parts[2] != "rpc" else {
            return Reply(status: 200, headers: json, body: Data("[]".utf8))
        }

        let items = components.queryItems ?? []
        var rows = rows(for: parts[2])
        for item in items {
            guard let value = item.value, value.hasPrefix("eq.") else { continue }
            let wanted = String(value.dropFirst(3))
            rows = rows.filter { row in
                guard let field = row[item.name] else { return true }
                return "\(field)" == wanted
            }
        }
        let total = rows.count
        let offset = items.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
        let limit = items.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? total
        let page = Array(rows.dropFirst(offset).prefix(limit))

        var headers = json
        headers["Content-Range"] = page.isEmpty
            ? "*/\(total)"
            : "\(offset)-\(offset + page.count - 1)/\(total)"

        let wantsObject = request.value(forHTTPHeaderField: "Accept")?.contains("vnd.pgrst.object") == true
        if wantsObject {
            guard let first = page.first,
                  let body = try? JSONSerialization.data(withJSONObject: first) else {
                return Reply(status: 406, headers: json, body: Data(#"{"code":"PGRST116"}"#.utf8))
            }
            return Reply(status: 200, headers: headers, body: body)
        }
        let body = (try? JSONSerialization.data(withJSONObject: page)) ?? Data("[]".utf8)
        return Reply(status: 200, headers: headers, body: body)
    }

    /// Decodes a fixture table into the app's model (for screens that take
    /// a model directly).
    static func decode<T: Decodable>(_ type: T.Type, table: String) -> [T] {
        guard let data = try? JSONSerialization.data(withJSONObject: rows(for: table)) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    // MARK: Dates

    private static func day(_ offset: Int) -> String {
        AppDateFormatters.isoDate.string(
            from: Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        )
    }

    private static func timestamp(_ offset: Int, _ time: String = "09:30:00") -> String {
        "\(day(offset))T\(time)+00:00"
    }

    // MARK: Tables

    static func rows(for table: String) -> [[String: Any]] {
        switch table {
        case "savings_goals": savingsGoals
        case "savings_contributions": savingsContributions
        case "deposits": deposits
        case "deposit_contributions": depositContributions
        case "savings_challenges": challenges
        case "achievements": achievements
        case "user_achievements": userAchievements
        case "categories": categories
        default: []
        }
    }

    private static var savingsGoals: [[String: Any]] {
        [
            ["id": "goal-1", "user_id": "demo", "name": "Vacation", "icon": "✈️", "color": "#60A5FA",
             "target_amount": 300000, "current_amount": 142500, "currency": "RUB",
             "deadline": day(140), "account_id": "demo-acc-2", "status": "active", "priority": 0,
             "reminder_enabled": false, "created_at": timestamp(-90)],
            ["id": "goal-2", "user_id": "demo", "name": "New laptop", "icon": "💻", "color": "#A78BFA",
             "target_amount": 120000, "current_amount": 84000, "currency": "RUB",
             "status": "active", "priority": 1, "reminder_enabled": false, "created_at": timestamp(-60)],
            ["id": "goal-3", "user_id": "demo", "name": "Emergency fund", "icon": "🏦", "color": "#4ADE80",
             "target_amount": 100000, "current_amount": 100000, "currency": "RUB",
             "status": "completed", "priority": 2, "reminder_enabled": false, "created_at": timestamp(-200)],
        ]
    }

    private static var savingsContributions: [[String: Any]] {
        [
            ["id": "contrib-1", "goal_id": "goal-1", "user_id": "demo", "amount": 50000,
             "type": "contribution", "note": "Bonus", "created_at": timestamp(-5)],
            ["id": "contrib-2", "goal_id": "goal-1", "user_id": "demo", "amount": 7500,
             "type": "withdrawal", "note": "Tickets deposit", "created_at": timestamp(-20)],
            ["id": "contrib-3", "goal_id": "goal-1", "user_id": "demo", "amount": 100000,
             "type": "contribution", "created_at": timestamp(-60)],
            ["id": "contrib-4", "goal_id": "goal-2", "user_id": "demo", "amount": 84000,
             "type": "contribution", "created_at": timestamp(-30)],
        ]
    }

    private static var deposits: [[String: Any]] {
        [
            ["id": "deposit-1", "user_id": "demo", "account_id": "demo-acc-2", "interest_rate": 14.5,
             "compound_frequency": "monthly", "start_date": day(-120), "end_date": day(245),
             "early_close_penalty_rate": 0, "status": "active", "return_to_account_id": "demo-acc-1",
             "created_at": timestamp(-120)],
            ["id": "deposit-2", "user_id": "demo", "account_id": "harness-deposit-2", "interest_rate": 12,
             "compound_frequency": "quarterly", "start_date": day(-400), "end_date": day(-35),
             "early_close_penalty_rate": 0, "status": "matured", "created_at": timestamp(-400)],
        ]
    }

    /// Amounts are minor units (bigint), like the table.
    private static var depositContributions: [[String: Any]] {
        [
            ["id": "dc-1", "deposit_id": "deposit-1", "user_id": "demo", "amount": 30_000_000,
             "contributed_at": day(-120), "source_account_id": "demo-acc-1", "created_at": timestamp(-120)],
            ["id": "dc-2", "deposit_id": "deposit-1", "user_id": "demo", "amount": 5_000_000,
             "contributed_at": day(-30), "source_account_id": "demo-acc-1", "created_at": timestamp(-30)],
            ["id": "dc-3", "deposit_id": "deposit-2", "user_id": "demo", "amount": 10_000_000,
             "contributed_at": day(-400), "created_at": timestamp(-400)],
        ]
    }

    private static var challenges: [[String: Any]] {
        [
            ["id": "ch-1", "user_id": "demo", "type": "no_cafe", "title": "No coffee shops",
             "duration_days": 30, "start_date": day(-10), "end_date": day(20),
             "status": "active", "progress_amount": 0, "created_at": timestamp(-10)],
            ["id": "ch-2", "user_id": "demo", "type": "weekly_amount", "title": "Save 5 000 a week",
             "target_amount": 20000, "duration_days": 30, "start_date": day(-18), "end_date": day(12),
             "status": "active", "progress_amount": 12500, "created_at": timestamp(-18)],
            ["id": "ch-3", "user_id": "demo", "type": "category_limit", "title": "Groceries under 15 000",
             "target_amount": 15000, "duration_days": 30, "start_date": day(-40), "end_date": day(-10),
             "status": "completed", "progress_amount": 11200, "category_id": "demo-cat-1",
             "created_at": timestamp(-40)],
        ]
    }

    private static func achievement(_ id: String, _ category: String, _ name: String, _ icon: String,
                                     _ tier: String, _ points: Int, secret: Bool = false,
                                     order: Int) -> [String: Any] {
        ["id": id, "key": id, "category": category, "name_ru": name, "name_en": name,
         "description_en": name, "icon": icon, "tier": tier, "points": points,
         "condition_type": "count", "is_secret": secret, "sort_order": order]
    }

    private static var achievements: [[String: Any]] {
        [
            achievement("ach-1", "getting_started", "First step", "🚀", "bronze", 10, order: 1),
            achievement("ach-2", "getting_started", "Budgeter", "🎯", "bronze", 10, order: 2),
            achievement("ach-3", "streaks", "Week streak", "🔥", "silver", 25, order: 3),
            achievement("ach-4", "streaks", "Month streak", "📅", "gold", 50, order: 4),
            achievement("ach-5", "transactions", "Hundred entries", "📊", "silver", 25, order: 5),
            achievement("ach-6", "savings", "Goal reached", "💰", "gold", 50, order: 6),
            achievement("ach-7", "ai", "Curious mind", "🤖", "bronze", 10, order: 7),
            achievement("ach-8", "advanced", "Master", "💎", "diamond", 100, order: 8),
            achievement("ach-9", "secret", "Night owl", "🦉", "gold", 50, secret: true, order: 9),
        ]
    }

    private static var userAchievements: [[String: Any]] {
        func row(_ id: String, unlocked: Bool, progress: Double) -> [String: Any] {
            var row: [String: Any] = ["id": "ua-\(id)", "user_id": "demo", "achievement_id": id,
                                      "progress": progress, "notified": true]
            if unlocked { row["unlocked_at"] = timestamp(-7) }
            return row
        }
        return [
            row("ach-1", unlocked: true, progress: 1),
            row("ach-2", unlocked: true, progress: 1),
            row("ach-3", unlocked: true, progress: 1),
            row("ach-4", unlocked: false, progress: 0.4),
            row("ach-5", unlocked: false, progress: 0.7),
            row("ach-6", unlocked: true, progress: 1),
            row("ach-8", unlocked: false, progress: 0.1),
        ]
    }

    private static var categories: [[String: Any]] {
        func row(_ id: String, _ name: String, _ icon: String, _ color: String, _ type: String,
                 active: Bool = true) -> [String: Any] {
            ["id": id, "user_id": "demo", "name": name, "icon": icon, "color": color,
             "type": type, "is_active": active, "created_at": "2025-01-01"]
        }
        return [
            row("demo-cat-1", "Groceries", "🛒", "#F472B6", "expense"),
            row("demo-cat-2", "Transport", "🚕", "#FBBF24", "expense"),
            row("demo-cat-3", "Coffee", "☕", "#FB923C", "expense"),
            row("demo-cat-4", "Entertainment", "🎬", "#A78BFA", "expense"),
            row("demo-cat-5", "Shopping", "👕", "#38BDF8", "expense"),
            row("demo-cat-6", "Salary", "💰", "#4ADE80", "income"),
            row("harness-cat-7", "Gym", "🏋️", "#34D399", "expense", active: false),
        ]
    }

    // MARK: Journal

    static let journalTags = ["food", "budget", "monthly", "subscriptions", "travel", "gifts", "health"]

    static func notes() -> [FinancialNote] {
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let monthEnd = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart) ?? Date()
        return [
            FinancialNote(
                id: "note-1", userId: "demo", title: "Big grocery run",
                content: "Stocked up for the week — prices went up again, mostly dairy and fruit.",
                transactionId: "demo-tx-1", tags: ["food", "budget"], mood: .worried,
                noteType: .freeform, createdAt: timestamp(0, "09:15:00")
            ),
            FinancialNote(
                id: "note-2", userId: "demo", title: "Monthly check-in",
                content: "### What went well?\nStayed under the grocery budget.\n\n### What will I change?\nFewer taxis, more walking.",
                tags: ["monthly"], mood: .good, noteType: .reflection,
                periodStart: AppDateFormatters.isoDate.string(from: monthStart),
                periodEnd: AppDateFormatters.isoDate.string(from: monthEnd),
                createdAt: timestamp(-1, "21:40:00")
            ),
            FinancialNote(
                id: "note-3", userId: "demo",
                content: "Cancelled the unused gym subscription — 2 990 ₽ a month back.",
                tags: ["subscriptions", "health"], mood: .great,
                noteType: .freeform, createdAt: timestamp(-3, "18:05:00")
            ),
        ]
    }
}

// MARK: - Screen routes

/// `-AkifiUIHarnessScreen <rawValue>`.
enum UIHarnessScreen: String, CaseIterable, Hashable {
    // Settings and its pushes
    case settings, beta, profile, categories, notifications, ai, theme, language, layout
    case baseCurrency, activeCurrencies, paymentDefaults, export, bankImport, reconciliation
    case premium, tags
    // Beta features
    case savings, savingsDetail, savingsForm, contribution
    case deposits, depositDetail, depositForm
    case challenges, challengeDetail, challengeForm
    case achievements, skillTree, levelUp, streak
    case fire, compound
    case journal, journalDetail, journalForm
    // Shared components
    case components, receipt, currencyPicker

    static var current: UIHarnessScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-AkifiUIHarnessScreen"), index + 1 < args.count else { return nil }
        return UIHarnessScreen(rawValue: args[index + 1])
    }

    enum Presentation { case root, push, sheet, overlay }

    var presentation: Presentation {
        switch self {
        case .settings, .journal, .components: .root
        case .savingsForm, .contribution, .depositForm, .challengeDetail, .challengeForm,
             .journalForm, .receipt, .currencyPicker: .sheet
        case .levelUp, .streak: .overlay
        default: .push
        }
    }
}

/// Hosts the screen chosen with `-AkifiUIHarnessScreen`.
struct UIHarnessScreenHost: View {
    let screen: UIHarnessScreen
    @State private var path: [UIHarnessScreen]
    @State private var showSheet = true
    @State private var overlayRun = 0

    init(screen: UIHarnessScreen) {
        self.screen = screen
        _path = State(initialValue: screen.presentation == .push ? [screen] : [])
    }

    var body: some View {
        switch screen.presentation {
        case .root:
            rootScreen
        case .push:
            NavigationStack(path: $path) {
                SettingsView()
                    .navigationDestination(for: UIHarnessScreen.self) { UIHarnessPushedScreen(screen: $0) }
            }
        case .sheet:
            NavigationStack {
                SettingsView()
            }
            .sheet(isPresented: $showSheet) {
                UIHarnessSheetScreen(screen: screen)
            }
        case .overlay:
            ZStack {
                MainTabView()
                overlay
                    .id(overlayRun)
            }
        }
    }

    @ViewBuilder
    private var rootScreen: some View {
        switch screen {
        case .journal:
            JournalTabView()
        case .components:
            NavigationStack { UIHarnessComponentsGallery() }
        default:
            NavigationStack { SettingsView() }
        }
    }

    /// The celebration overlays dismiss themselves after a few seconds;
    /// the harness shows them again so a screenshot can't miss them.
    @ViewBuilder
    private var overlay: some View {
        if screen == .levelUp {
            LevelUpView(achievementName: "Goal reached", points: 50, icon: "💰", tier: "gold") {
                overlayRun += 1
            }
        } else {
            StreakMilestoneView(info: StreakTracker.info(for: 30)) {
                overlayRun += 1
            }
        }
    }
}

private struct UIHarnessPushedScreen: View {
    let screen: UIHarnessScreen
    @Environment(AppViewModel.self) private var app

    var body: some View {
        switch screen {
        case .beta: BetaFeaturesView()
        case .profile: ProfileEditView()
        case .categories: CategoriesManagementView()
        case .notifications: NotificationSettingsView()
        case .ai: AISettingsView()
        case .theme: ThemePickerView()
        case .language: LanguagePickerView()
        case .layout: CategoryLayoutPickerView()
        case .baseCurrency: BaseCurrencyPickerView()
        case .activeCurrencies: ManageActiveCurrenciesView()
        case .paymentDefaults: PaymentDefaultsView()
        case .export: ExportView()
        case .bankImport: BankImportView()
        case .reconciliation: CurrencyReconciliationView()
        case .premium: PremiumPaywallView()
        case .tags: TagManagementView()
        case .savings: SavingsGoalListView()
        case .savingsDetail: savingsDetail
        case .deposits: DepositListView()
        case .depositDetail: UIHarnessDepositDetail()
        case .challenges: ChallengesListView()
        case .achievements: AchievementsView()
        case .skillTree: SkillTreeView()
        case .fire: FIREProjectionView()
        case .compound: CompoundCalculatorView()
        case .journalDetail:
            if let note = UIHarnessFixtures.notes().first(where: { $0.noteType == .reflection }) {
                JournalNoteDetailView(note: note, viewModel: app.journalViewModel, dataStore: app.dataStore)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var savingsDetail: some View {
        let goals = UIHarnessFixtures.decode(SavingsGoal.self, table: "savings_goals")
        let contributions = UIHarnessFixtures.decode(SavingsContribution.self, table: "savings_contributions")
        if let goal = goals.first {
            SavingsGoalDetailView(
                goal: goal,
                contributions: contributions.filter { $0.goalId == goal.id },
                progress: Double(goal.currentAmount) / Double(max(goal.targetAmount, 1)),
                daysRemaining: 140
            ) { _, _, _, _ in }
        }
    }
}

/// Deposit detail with a loaded view model (the list normally provides it).
private struct UIHarnessDepositDetail: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel = DepositsViewModel()

    var body: some View {
        Group {
            if let deposit = viewModel.deposits.first {
                DepositDetailView(deposit: deposit, viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task { await viewModel.load(dataStore: app.dataStore) }
    }
}

private struct UIHarnessSheetScreen: View {
    let screen: UIHarnessScreen
    @Environment(AppViewModel.self) private var app
    @State private var currency: Currency = .rub

    var body: some View {
        switch screen {
        case .savingsForm:
            SavingsGoalFormView(accounts: app.dataStore.accounts) { _ in }
        case .contribution:
            if let goal = UIHarnessFixtures.decode(SavingsGoal.self, table: "savings_goals").first {
                ContributionSheetView(goal: goal) { _, _, _, _ in }
            }
        case .depositForm:
            DepositFormView(viewModel: DepositsViewModel())
        case .challengeDetail:
            if let challenge = UIHarnessFixtures.decode(SavingsChallenge.self, table: "savings_challenges")
                .first(where: { $0.type == .weeklyAmount }) {
                ChallengeDetailView(challenge: challenge, onAbandon: {}, onDelete: {})
            }
        case .challengeForm:
            ChallengeFormView { _ in }
        case .journalForm:
            JournalNoteFormView(viewModel: app.journalViewModel, initialType: .reflection)
        case .receipt:
            ReceiptScannerView {}
        case .currencyPicker:
            CurrencyPickerView(selection: $currency)
        default:
            EmptyView()
        }
    }
}

/// The shared components of `Views/Shared` on one screen.
private struct UIHarnessComponentsGallery: View {
    @State private var calculator: CalculatorState = {
        let state = CalculatorState()
        state.handleDigit("1")
        state.handleDigit("2")
        state.handleDigit("5")
        state.handleOperator(.add)
        state.handleDigit("4")
        state.handleDigit("0")
        return state
    }()
    @State private var selectedChip = 0
    @State private var currency: Currency = .rub

    var body: some View {
        List {
            Section(header: Text(verbatim: "FilterChip")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<4) { index in
                            FilterChip(title: ["All", "#food", "#travel", "+3"][index],
                                       isSelected: selectedChip == index) { selectedChip = index }
                        }
                    }
                }
            }

            Section(header: Text(verbatim: "SettingsRow / ActiveCurrencyPicker")) {
                SettingsRow(icon: "bell.fill", color: .red, title: "Notifications")
                SettingsRow(icon: "flask.fill", color: .orange, title: "Beta features", badge: "BETA")
                SettingsRow(icon: "hand.raised.fill", color: .blue, title: "Privacy", isExternalLink: true)
                HStack {
                    Text(verbatim: "Currency")
                    Spacer()
                    ActiveCurrencyPicker(selection: $currency)
                }
            }

            Section(header: Text(verbatim: "EmptyStateView")) {
                EmptyStateView(
                    title: String(localized: "savings.noGoals"),
                    systemImage: "target",
                    description: String(localized: "savings.noGoals.description"),
                    actionTitle: String(localized: "common.create")
                ) {}
                .listRowBackground(Color.clear)
            }

            Section(header: Text(verbatim: "LoadingView")) {
                LoadingView()
                    .frame(height: 80)
            }

            Section(header: Text(verbatim: "CalculatorKeyboardView")) {
                CalculatorKeyboardView(state: calculator)
                    .listRowInsets(EdgeInsets())
            }

            Section(header: Text(verbatim: "demoBlur")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Monthly budget").font(.headline)
                    ProgressView(value: 0.6)
                    Text(verbatim: "12 400 ₽ of 20 000 ₽").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(height: 150, alignment: .top)
                .demoBlur(hint: String(localized: "welcome.budgetHint"),
                          buttonTitle: String(localized: "common.create")) {}
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(Text(verbatim: "Views/Shared"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
