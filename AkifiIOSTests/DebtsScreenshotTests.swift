import SwiftUI
import XCTest
@testable import AkifiIOS

/// Renders every new «Долги» / personal-spending screen with fixture data
/// (offline DataStore, fake debts server — no network writes, no sign-in)
/// into PNGs, light and dark. Skipped unless `AKIFI_SNAPSHOT_DIR` is set:
///
///     TEST_RUNNER_AKIFI_SNAPSHOT_DIR=/path xcodebuild test … \
///       -only-testing:AkifiIOSTests/DebtsScreenshotTests
///
/// A real `UIWindow` hosts the views (List / Form / NavigationStack are
/// UIKit-backed — `ImageRenderer` can't draw them).
@MainActor
final class DebtsScreenshotTests: XCTestCase {

    private var outputDir: URL!
    private var tempDir: URL!

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["AKIFI_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set AKIFI_SNAPSHOT_DIR to render screenshots")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DebtShots-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Fixtures

    nonisolated static let me = "aaaa-me"
    nonisolated static let partner = "bbbb-partner"

    private func makeApp() -> AppViewModel {
        let store = DataStore(cache: PersistenceManager(directory: tempDir))
        store.isConnectedProvider = { false }
        let app = AppViewModel(dataStore: store)
        let cm = app.currencyManager
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.apply(FXRateSnapshot.fromNetwork(["USD": 1, "RUB": 92], at: Date()))

        let card = Account(id: "card", userId: Self.me, name: "Тинькофф", icon: "💳", color: "#3B82F6",
                           initialBalance: 85_400_00, isPrimary: true, currency: "rub", createdAt: "2026-01-01")
        let cash = Account(id: "cash", userId: Self.me, name: "Наличные", icon: "💵", color: "#10B981",
                           initialBalance: 6_200_00, currency: "rub", accountType: .cash, createdAt: "2026-01-02")
        let family = Account(id: "family", userId: Self.me, name: "Семейный", icon: "👪", color: "#8B5CF6",
                             initialBalance: 40_000_00, currency: "rub", createdAt: "2026-01-03")
        let masha = Account(id: "d-masha", userId: Self.me, name: "Маша", icon: "👤", color: "#F59E0B",
                            initialBalance: 0, currency: "rub", accountType: .debt, createdAt: "2026-11-01T10:00:00Z")
        let petya = Account(id: "d-petya", userId: Self.me, name: "Петя Смирнов", icon: "👤", color: "#10B981",
                            initialBalance: 0, currency: "rub", accountType: .debt, createdAt: "2026-11-05T10:00:00Z")
        let john = Account(id: "d-john", userId: Self.me, name: "John", icon: "👤", color: "#3B82F6",
                           initialBalance: 0, currency: "usd", accountType: .debt, createdAt: "2026-10-01T10:00:00Z")
        let oleg = Account(id: "d-oleg", userId: Self.me, name: "Олег", icon: "👤", color: "#F43F5E",
                           initialBalance: 0, currency: "rub", accountType: .debt, createdAt: "2026-09-01T10:00:00Z")
        store.allAccounts = [card, cash, family, masha, petya, john, oleg]

        func leg(_ id: String, _ account: String, _ type: TransactionType, _ minor: Int64, group: String, date: String,
                 desc: String? = nil, personal: String? = nil, user: String = DebtsScreenshotTests.me) -> AkifiIOS.Transaction {
            AkifiIOS.Transaction(id: id, userId: user, accountId: account, amount: minor, currency: "RUB", description: desc,
                        categoryId: nil, type: type, date: String(date.prefix(10)), rawDateTime: date,
                        merchantName: nil, merchantFuzzy: nil, transferGroupId: group, personalDebtUserId: personal,
                        status: nil, createdAt: date, updatedAt: nil)
        }
        store.transactions = [
            // Маша: lent 5 000, got 2 000 back → owes 3 000.
            leg("m1o", "card", .expense, 5_000_00, group: "gm1", date: "2026-11-02T12:00:00", desc: "Долг: Маша · на ремонт"),
            leg("m1i", "d-masha", .income, 5_000_00, group: "gm1", date: "2026-11-02T12:00:00", desc: "Долг: Маша · на ремонт"),
            leg("m2o", "d-masha", .expense, 2_000_00, group: "gm2", date: "2026-11-20T18:30:00", desc: "Долг: Маша"),
            leg("m2i", "cash", .income, 2_000_00, group: "gm2", date: "2026-11-20T18:30:00", desc: "Долг: Маша"),
            // Петя: borrowed 1 000, repaid 300.55 → I owe 699.45.
            leg("p1o", "d-petya", .expense, 1_000_00, group: "gp1", date: "2026-11-06T09:00:00"),
            leg("p1i", "card", .income, 1_000_00, group: "gp1", date: "2026-11-06T09:00:00"),
            leg("p2o", "card", .expense, 300_55, group: "gp2", date: "2026-11-15T09:00:00"),
            leg("p2i", "d-petya", .income, 300_55, group: "gp2", date: "2026-11-15T09:00:00"),
            // John: lent $120 (overdue).
            leg("j1o", "card", .expense, 11_040_00, group: "gj1", date: "2026-10-02T09:00:00"),
            leg("j1i", "d-john", .income, 120_00, group: "gj1", date: "2026-10-02T09:00:00"),
            // Олег: settled and closed.
            leg("o1o", "card", .expense, 700_00, group: "go1", date: "2026-09-02T09:00:00"),
            leg("o1i", "d-oleg", .income, 700_00, group: "go1", date: "2026-09-02T09:00:00"),
            leg("o2o", "d-oleg", .expense, 700_00, group: "go2", date: "2026-09-20T09:00:00"),
            leg("o2i", "card", .income, 700_00, group: "go2", date: "2026-09-20T09:00:00"),
            // «Семейный»: my personal expense from the account's own money,
            // part of it repaid.
            AkifiIOS.Transaction(id: "fam-e", userId: Self.me, accountId: "family", amount: 2_450_00, currency: "RUB",
                        description: "Кроссовки", categoryId: "cat-shop", type: .expense, date: "2026-11-24",
                        rawDateTime: "2026-11-24T19:10:00", merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
                        personalDebtUserId: Self.me, status: nil, createdAt: nil, updatedAt: nil),
            leg("fr-o", "card", .expense, 1_000_00, group: "gfr", date: "2026-11-25T10:00:00"),
            leg("fr-i", "family", .income, 1_000_00, group: "gfr", date: "2026-11-25T10:00:00", personal: Self.me),
        ]
        store.categories = [
            Category(id: "cat-shop", userId: Self.me, accountId: nil, name: "Покупки", icon: "🛍️", color: "#8B5CF6",
                     type: .expense, isActive: true, createdAt: nil),
            Category(id: "cat-food", userId: Self.me, accountId: nil, name: "Продукты", icon: "🛒", color: "#10B981",
                     type: .expense, isActive: true, createdAt: nil),
        ]
        store.profile = Profile(id: Self.me, email: nil, fullName: "Владимир", avatarUrl: nil, defaultCurrency: "RUB",
                                telegramUserId: nil, telegramChatId: nil, telegramLinkedAt: nil, updatedAt: nil)
        store.profilesMap = [
            Self.me: store.profile!,
            Self.partner: Profile(id: Self.partner, email: nil, fullName: "Аня", avatarUrl: nil, defaultCurrency: "RUB",
                                  telegramUserId: nil, telegramChatId: nil, telegramLinkedAt: nil, updatedAt: nil),
        ]
        store.accountMembership.apply([
            AccountMember(id: "fm1", accountId: "family", userId: Self.me, role: .owner),
            AccountMember(id: "fm2", accountId: "family", userId: Self.partner, role: .editor),
            AccountMember(id: "cm1", accountId: "card", userId: Self.me, role: .owner),
        ], for: Self.me)
        store.rebuildCaches()

        let summary = DebtsSummary(version: 1, today: "2026-11-28", debts: [
            DebtsSummary.Entry(accountId: "d-masha", name: "Маша", icon: "👤", color: "#F59E0B", currency: "RUB",
                               balance: 3_000_00, counterpartyName: "Маша", counterpartyContact: "+7 900 000-00-00",
                               dueDate: "2026-12-31", remind: true, note: "На ремонт кухни", txCount: 2,
                               createdAt: "2026-11-01T10:00:00Z"),
            DebtsSummary.Entry(accountId: "d-petya", name: "Петя Смирнов", icon: "👤", color: "#10B981", currency: "RUB",
                               balance: -699_45, counterpartyName: "Петя Смирнов", txCount: 2, createdAt: "2026-11-05T10:00:00Z"),
            DebtsSummary.Entry(accountId: "d-john", name: "John", icon: "👤", color: "#3B82F6", currency: "USD",
                               balance: 120_00, counterpartyName: "John", dueDate: "2026-11-15", isOverdue: true,
                               txCount: 1, createdAt: "2026-10-01T10:00:00Z"),
            DebtsSummary.Entry(accountId: "d-oleg", name: "Олег", icon: "👤", color: "#F43F5E", currency: "RUB",
                               balance: 0, counterpartyName: "Олег", closedAt: "2026-09-21T10:00:00Z", txCount: 2,
                               createdAt: "2026-09-01T10:00:00Z"),
        ])
        app.debts.remote = DebtsStore.Remote(
            fetchSummary: { summary },
            create: { $0.p_account_id }, updateDetails: { _, _ in }, rename: { _, _ in },
            setClosed: { _, _ in }, delete: { _ in }, currentUserId: { Self.me }
        )
        app.debts.reminders = DebtReminderScheduler(pendingIdentifiers: { [] }, schedule: { _ in }, cancel: { _ in })
        app.debts.apply(summary, userId: Self.me, mutationMark: store.mutationGeneration)
        return app
    }

    // MARK: - Rendering

    private func render<V: View>(_ name: String, height: CGFloat? = nil, @ViewBuilder _ content: () -> V) async throws {
        let app = makeApp()
        let view = content()
            .environment(app)
            .environment(CurrentAccountContext())
        for style in [UIUserInterfaceStyle.light, .dark] {
            try await snapshot(AnyView(view), name: "\(name)-\(style == .dark ? "dark" : "light")", style: style, height: height)
        }
    }

    private func snapshot(_ view: AnyView, name: String, style: UIUserInterfaceStyle, height: CGFloat?) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        if let height {
            window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: height)
        }
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2.0))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.5))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: outputDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
        window.rootViewController = nil
    }

    // MARK: - Screens

    func test_01_debtsList() async throws {
        try await render("01-debts-list") { NavigationStack { DebtsListView() } }
    }

    func test_02_debtDetail() async throws {
        try await render("02-debt-detail") { NavigationStack { DebtDetailView(accountId: "d-masha") } }
    }

    func test_03_debtDetailIOwe() async throws {
        try await render("03-debt-detail-i-owe") { NavigationStack { DebtDetailView(accountId: "d-petya") } }
    }

    func test_04_addPerson() async throws {
        try await render("04-add-person") { DebtFormSheet(mode: .create(initial: .lend)) }
    }

    func test_05_movementGotRepaid() async throws {
        try await render("05-movement-got-repaid") { DebtMovementSheet(debtAccountId: "d-masha", action: .gotRepaid) }
    }

    func test_06_movementBorrowCrossCurrency() async throws {
        try await render("06-movement-lend-usd") { DebtMovementSheet(debtAccountId: "d-john", action: .lend) }
    }

    func test_07_quickAction() async throws {
        try await render("07-quick-action-lend") { DebtQuickActionSheet(action: .lend) }
    }

    func test_08_homeCard() async throws {
        // Inside a NavigationStack like on Home (a link outside one is disabled).
        try await render("08-home-card", height: 360) {
            NavigationStack {
                ScrollView {
                    DebtsHomeEntry()
                        .padding()
                }
                .background(Color(.systemGroupedBackground))
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    func test_09_expenseFormPersonal() async throws {
        let personalExpense = AkifiIOS.Transaction(
            id: "fam-e", userId: Self.me, accountId: "family", amount: 2_450_00, currency: "RUB",
            description: "Кроссовки", categoryId: "cat-shop", type: .expense, date: "2026-11-24",
            rawDateTime: "2026-11-24T19:10:00", merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            personalDebtUserId: Self.me, status: nil, createdAt: nil, updatedAt: nil
        )
        let app = makeApp()
        let view = TransactionFormView(
            categories: app.dataStore.displayCategories, accounts: app.dataStore.accounts,
            editingTransaction: personalExpense
        ) {}
        for style in [UIUserInterfaceStyle.light, .dark] {
            try await snapshot(AnyView(view.environment(app).environment(CurrentAccountContext())),
                               name: "09-expense-form-personal-\(style == .dark ? "dark" : "light")", style: style, height: 1450)
        }
    }

    func test_10_personalDebtCard() async throws {
        let app = makeApp()
        let vm = SettlementViewModel()
        vm.members = [
            AccountMember(id: "fm1", accountId: "family", userId: Self.me, role: .owner),
            AccountMember(id: "fm2", accountId: "family", userId: Self.partner, role: .editor),
        ]
        vm.personalDebts = [
            SettlementCalculator.PersonalDebt(userId: Self.me, expenses: 2_450_00, repaid: 1_000_00, isMember: true),
            SettlementCalculator.PersonalDebt(userId: Self.partner, expenses: 800_00, repaid: 0, isMember: true),
        ]
        let family = try XCTUnwrap(app.dataStore.account(withId: "family"))
        let view = ScrollView {
            PersonalDebtCard(account: family, viewModel: vm).padding()
        }
        .background(Color(.systemGroupedBackground))
        for style in [UIUserInterfaceStyle.light, .dark] {
            try await snapshot(AnyView(view.environment(app)), name: "10-personal-debt-card-\(style == .dark ? "dark" : "light")",
                               style: style, height: 460)
        }
    }

    func test_11_repaySheet() async throws {
        let app = makeApp()
        let family = try XCTUnwrap(app.dataStore.account(withId: "family"))
        let view = RepayPersonalDebtSheet(sharedAccount: family, owed: 1_450_00) {}
        for style in [UIUserInterfaceStyle.light, .dark] {
            try await snapshot(AnyView(view.environment(app)), name: "11-repay-personal-debt-\(style == .dark ? "dark" : "light")",
                               style: style, height: nil)
        }
    }

    func test_12_netWorthDebtsCard() async throws {
        try await render("12-networth-debts-card", height: 300) {
            NavigationStack {
                VStack {
                    NavigationLink { DebtsListView() } label: { DebtsSummaryCard() }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding()
                .background(Color(.systemGroupedBackground))
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}
