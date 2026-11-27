import XCTest
@testable import AkifiIOS

/// Contract §A7: a debt balance is not spendable money. `DataStore.accounts`
/// is the one source of lists, pickers and totals and never holds a debt
/// (or an unknown type); `allAccounts` exists only to resolve ids.
@MainActor
final class DebtExclusionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DebtExcl-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    static let card = Account(id: "card", userId: "me", name: "Карта", icon: "💳", color: "#3B82F6",
                              initialBalance: 10_000_00, isPrimary: true, currency: "rub")
    static let cash = Account(id: "cash", userId: "me", name: "Наличные", icon: "💵", color: "#10B981",
                              initialBalance: 2_000_00, currency: "rub", accountType: .cash)
    static let masha = Account(id: "debt-masha", userId: "me", name: "Маша", icon: "👤", color: "#F59E0B",
                               initialBalance: 0, currency: "rub", accountType: .debt)
    static let future = Account(id: "future", userId: "me", name: "Новый тип", icon: "?", color: "#000",
                                initialBalance: 5_000_00, currency: "rub", accountType: .unsupported)

    /// «Дал в долг» 3 000 ₽ from the card: two legs.
    static func lendLegs(amount: Int64 = 3_000_00) -> [Transaction] {
        let group = "g-lend"
        return [
            Transaction(id: "l-out", userId: "me", accountId: "card", amount: amount, currency: "RUB",
                        description: "Долг: Маша", categoryId: nil, type: .expense, date: "2026-11-28",
                        merchantName: "Маша", merchantFuzzy: nil, transferGroupId: group, status: nil, createdAt: nil, updatedAt: nil),
            Transaction(id: "l-in", userId: "me", accountId: "debt-masha", amount: amount, currency: "RUB",
                        description: "Долг: Маша", categoryId: nil, type: .income, date: "2026-11-28",
                        merchantName: "Маша", merchantFuzzy: nil, transferGroupId: group, status: nil, createdAt: nil, updatedAt: nil),
        ]
    }

    private func makeStore() -> DataStore {
        let store = DataStore(cache: PersistenceManager(directory: tempDir))
        store.isConnectedProvider = { false }
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = ["USD": 1, "RUB": 100]
        store.currencyManager = cm
        store.allAccounts = [Self.card, Self.masha, Self.cash, Self.future]
        store.transactions = Self.lendLegs()
        store.rebuildCaches()
        return store
    }

    func test_accounts_isMoneyOnly() {
        let store = makeStore()
        XCTAssertEqual(store.accounts.map(\.id), ["card", "cash"])
        XCTAssertEqual(store.allAccounts.count, 4)
        XCTAssertEqual(store.debtAccounts.map(\.id), ["debt-masha"])
    }

    func test_accounts_followsAllAccounts() {
        let store = makeStore()
        store.allAccounts.removeAll { $0.id == "cash" }
        XCTAssertEqual(store.accounts.map(\.id), ["card"])
        store.allAccounts.append(Self.cash)
        XCTAssertEqual(store.accounts.map(\.id), ["card", "cash"])
    }

    func test_idLookupResolvesDebtAccounts() {
        let store = makeStore()
        XCTAssertEqual(store.account(withId: "debt-masha")?.name, "Маша")
        XCTAssertNil(store.account(withId: nil))
    }

    /// The debt keeps its own balance; the card shows the money that left.
    func test_balances() {
        let store = makeStore()
        XCTAssertEqual(store.balance(for: Self.masha), 3_000_00)
        XCTAssertEqual(store.balance(for: Self.card), 7_000_00)
    }

    /// Home "всего на счетах" / Analytics total: money accounts only.
    func test_totalBalance_excludesDebts() {
        let store = makeStore()
        let total = store.accounts.reduce(Int64(0)) { $0 + store.balance(for: $1) }
        XCTAssertEqual(total, 9_000_00, "card 7 000 + cash 2 000; Маша's 3 000 and the unknown type are out")
    }

    func test_widgetSnapshot_excludesDebts() {
        let store = makeStore()
        let snapshot = SharedSnapshotWriter.buildSnapshot(dataStore: store, currencyManager: store.currencyManager!)
        XCTAssertEqual(snapshot.totalBalance, 9_000_00)
        XCTAssertEqual(snapshot.accountCount, 2)
    }

    /// C3: the assistant never gets a debt account in `context.accounts`.
    func test_assistantContext_excludesDebts() {
        let store = makeStore()
        let ctx = store.buildAssistantContext()
        XCTAssertEqual(Set(ctx.accounts.map(\.id)), ["card", "cash"])
        XCTAssertEqual(ctx.totalBalance, 9_000, accuracy: 0.001)
    }

    func test_formsDropDebtAccounts() {
        XCTAssertEqual([Self.masha, Self.card, Self.future].moneyAccounts.map(\.id), ["card"])
    }

    /// A7.6: owed-to-me is an asset, I-owe a liability, never "on accounts".
    func test_netWorth_debtsAsAssetAndLiability() {
        let breakdown = NetWorthCalculator.compute(
            accountBalances: [("RUB", 9_000_00)],
            assets: [], liabilities: [], fxRates: ["USD": 1, "RUB": 100], baseCurrency: .rub,
            debtBalances: [("RUB", 3_000_00), ("RUB", -699_45), ("USD", 10_00)]
        )
        XCTAssertEqual(breakdown.accountsTotal, 9_000_00)
        XCTAssertEqual(breakdown.debtsOwedToMe, 3_000_00 + 1_000_00)
        XCTAssertEqual(breakdown.debtsIOwe, 699_45)
        XCTAssertEqual(breakdown.assetsTotal, 4_000_00)
        XCTAssertEqual(breakdown.liabilitiesTotal, 699_45)
        XCTAssertEqual(breakdown.netWorth, 9_000_00 + 4_000_00 - 699_45)
    }

    func test_netWorth_closedDebtLeavesTotals() {
        let open = DebtEntry(accountId: "a", name: "A", icon: nil, color: nil, currency: "RUB", balance: 500_00,
                             contact: nil, dueDate: nil, remind: false, note: nil, closedAt: nil, hasDetails: true, isOverdue: false, createdAt: nil)
        let closed = DebtEntry(accountId: "b", name: "B", icon: nil, color: nil, currency: "RUB", balance: 100_00,
                               contact: nil, dueDate: nil, remind: false, note: nil, closedAt: "2026-11-28T10:00:00Z", hasDetails: true, isOverdue: false, createdAt: nil)
        XCTAssertEqual(DebtMath.netWorthBalances([open, closed]).map(\.amount), [500_00])
    }

    /// Debt movements are transfers: never income/expense in the monthly
    /// aggregates analytics read.
    func test_debtMovementsAreNotCashflow() {
        let store = makeStore()
        XCTAssertTrue(store.monthlyAggregates.values.allSatisfy { $0.income == 0 && $0.expense == 0 })
    }
}

/// Fails when a file starts reading `allAccounts` / `debtAccounts` (a debt
/// would leak into a list, picker or total) without being reviewed and
/// added below with its reason. Every list must come from
/// `DataStore.accounts`; id lookups use `DataStore.account(withId:)`.
final class DebtExclusionGuardTests: XCTestCase {

    /// File (relative to `AkifiIOS/`) → why it may read every account.
    static let allowlist: [String: String] = [
        "Services/DataStore.swift": "owns the storage; caches and FX context cover every account",
        "Services/DataStore+NativeBalance.swift": "auto-transfer permission: is the source card visible",
        "Services/DerivedDataCache.swift": "memo identity of the account set",
        "Services/SharedSnapshotWriter.swift": "currency lookup per row; the total reads `accounts`",
        "Services/DebtMath.swift": "the «Долги» flows",
        "ViewModels/DebtsStore.swift": "the «Долги» flows",
        "Views/Debts/DebtsListView.swift": "the «Долги» flows",
        "Views/Journal/JournalNoteDetailView.swift": "id → currency lookups",
        "Views/Reports/ReportsView.swift": "PDF id → name / currency lookups",
        "Views/Settings/CurrencyReconciliationView.swift": "id lookups for legacy rows",
        "Views/Settings/ExportView.swift": "CSV names every row's account",
        "Debug/UIHarness.swift": "DEBUG-only screenshot fixtures write the store (compiled out of Release)",
    ]

    /// Any use of the identifiers (with or without `dataStore.` — the
    /// DataStore extensions read them as `self`), outside comments and
    /// string literals.
    private static let pattern = try! NSRegularExpression(pattern: #"\b(allAccounts|debtAccounts)\b"#)
    private static let stringLiteral = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)

    private func appSourcesRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AkifiIOS")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("App sources are not reachable from this test host")
        }
        return root
    }

    private func offenders(in root: URL) throws -> [String: [Int]] {
        var found: [String: [Int]] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
                var line = rawLine
                if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
                let ns = line as NSString
                line = Self.stringLiteral.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "\"\"")
                if Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                    found[rel, default: []].append(index + 1)
                }
            }
        }
        return found
    }

    func test_onlyReviewedFilesReadEveryAccount() throws {
        let found = try offenders(in: try appSourcesRoot())
        let unexpected = found.filter { Self.allowlist[$0.key] == nil }
        XCTAssertTrue(unexpected.isEmpty, """
            These files read `allAccounts` / `debtAccounts`: \(unexpected.map { "\($0.key):\($0.value)" }.sorted()).
            A list, picker or total must use `dataStore.accounts` (money only, contract §A7); an id lookup \
            `dataStore.account(withId:)`. If this really needs every account, add it to the allowlist with the reason.
            """)
    }

    /// Keeps the allowlist honest: an entry that no longer reads every
    /// account must be removed.
    func test_allowlistHasNoStaleEntries() throws {
        let found = try offenders(in: try appSourcesRoot())
        let stale = Self.allowlist.keys.filter { found[$0] == nil }
        XCTAssertTrue(stale.isEmpty, "Stale allowlist entries: \(stale.sorted())")
    }
}
