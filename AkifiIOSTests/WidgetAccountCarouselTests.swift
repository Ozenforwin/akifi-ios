import WidgetKit
import XCTest
@testable import AkifiIOS

/// 1.6.0 «Счёт» arrows and «Все счета»: cycling, the widget key, what a
/// remembered step resolves to (deleted ids, edited widgets), the step
/// intent's state, pruning, the account deep link and Home's carousel
/// mapping, the «Все счета» selection and total rule, the reload policy.
@MainActor
final class WidgetAccountCarouselTests: XCTestCase {

    // MARK: - Fixtures

    static let cardId = "0a000000-0000-4000-8000-000000000001"
    static let cashId = "0a000000-0000-4000-8000-000000000002"
    static let usdId = "0a000000-0000-4000-8000-000000000003"
    static let familyId = "0a000000-0000-4000-8000-000000000004"
    static let debtId = "0a000000-0000-4000-8000-000000000005"
    static let goneId = "0a000000-0000-4000-8000-0000000000ff"

    static func item(_ id: String, _ name: String, primary: Bool = false, hidden: Bool = false,
                     balance: Int64 = 1_00, color: String = "#3B82F6") -> SharedSnapshot.AccountItem {
        SharedSnapshot.AccountItem(id: id, name: name, icon: "💳", colorHex: color,
                                   currencyCode: "RUB", currencySymbol: "₽", currencyDecimals: 0,
                                   balance: balance, monthIncome: 0, monthExpense: 0,
                                   isPrimary: primary, isShared: false, isBalanceHidden: hidden)
    }

    static let card = item(cardId, "Тинькофф", primary: true)
    static let cash = item(cashId, "Наличные")
    static let usd = item(usdId, "ByBit")
    static let family = item(familyId, "Семейный")

    static func snapshot(_ accounts: [SharedSnapshot.AccountItem]?) -> SharedSnapshot {
        var s = SharedSnapshot.placeholder
        s.accounts = accounts
        return s
    }

    /// Card (primary), cash, USD, family — the carousel's order.
    static let four = snapshot([card, cash, usd, family])

    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "WidgetCarousel-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: - Cycling

    func test_neighbour_wrapsBothWays() {
        let accounts = [Self.card, Self.cash, Self.usd]
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.cardId, in: accounts, forward: true)?.id, Self.cashId)
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.cashId, in: accounts, forward: true)?.id, Self.usdId)
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.usdId, in: accounts, forward: true)?.id, Self.cardId, "› after the last → the first")
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.cardId, in: accounts, forward: false)?.id, Self.usdId, "‹ before the first → the last")
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.usdId, in: accounts, forward: false)?.id, Self.cashId)
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.cashId.uppercased(), in: accounts, forward: true)?.id, Self.usdId,
                       "ids compare case-insensitively")
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.goneId, in: accounts, forward: true)?.id, Self.cashId,
                       "an id not in the list counts as the first")
    }

    func test_neighbour_twoAccounts_bothArrowsReachTheOther() {
        let accounts = [Self.card, Self.cash]
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.cardId, in: accounts, forward: true)?.id, Self.cashId)
        XCTAssertEqual(AccountWidgetCarousel.neighbour(of: Self.cardId, in: accounts, forward: false)?.id, Self.cashId)
    }

    func test_neighbour_singleOrNoAccount_isNil() {
        XCTAssertNil(AccountWidgetCarousel.neighbour(of: Self.cardId, in: [Self.card], forward: true))
        XCTAssertNil(AccountWidgetCarousel.neighbour(of: Self.cardId, in: [Self.card], forward: false))
        XCTAssertNil(AccountWidgetCarousel.neighbour(of: Self.cardId, in: [], forward: true))
    }

    // MARK: - Widget key

    func test_widgetKey_accountAndFamily() {
        let small = AccountWidgetCarousel.widgetKey(configuredAccountId: Self.cardId, family: .systemSmall)
        let medium = AccountWidgetCarousel.widgetKey(configuredAccountId: Self.cardId, family: .systemMedium)
        XCTAssertEqual(small, "\(Self.cardId)@small")
        XCTAssertEqual(medium, "\(Self.cardId)@medium")
        XCTAssertNotEqual(small, medium, "a small and a medium widget of one account move independently")
        XCTAssertEqual(AccountWidgetCarousel.widgetKey(configuredAccountId: Self.cardId.uppercased(), family: .systemSmall), small)
        XCTAssertNotEqual(AccountWidgetCarousel.widgetKey(configuredAccountId: Self.cashId, family: .systemSmall), small,
                          "another configured account is another key")
        XCTAssertEqual(AccountWidgetCarousel.widgetKey(configuredAccountId: nil, family: .systemSmall), "default@small")
        XCTAssertEqual(AccountWidgetCarousel.widgetKey(configuredAccountId: "  ", family: .systemMedium), "default@medium")
    }

    func test_arrows_onlyOnHomeScreenFamilies() {
        XCTAssertTrue(AccountWidgetCarousel.showsArrows(in: .systemSmall))
        XCTAssertTrue(AccountWidgetCarousel.showsArrows(in: .systemMedium))
        XCTAssertFalse(AccountWidgetCarousel.showsArrows(in: .accessoryRectangular))
        XCTAssertFalse(AccountWidgetCarousel.showsArrows(in: .accessoryInline))
        XCTAssertFalse(AccountWidgetCarousel.showsArrows(in: .systemLarge))
    }

    // MARK: - Resolution

    private func content(_ snapshot: SharedSnapshot?, configured: String?, family: WidgetFamily = .systemSmall,
                         overrides: [String: AccountWidgetOverride] = [:]) -> AccountWidgetContent {
        AccountWidgetCarousel.content(snapshot: snapshot, configuredAccountId: configured, family: family, overrides: overrides)
    }

    private func key(_ configured: String?, _ family: WidgetFamily = .systemSmall) -> String {
        AccountWidgetCarousel.widgetKey(configuredAccountId: configured, family: family)
    }

    func test_content_withoutSteps_isTheConfiguredAccount_withPager() throws {
        let c = content(Self.four, configured: Self.usdId)
        XCTAssertEqual(c.state.account?.id, Self.usdId)
        let pager = try XCTUnwrap(c.pager)
        XCTAssertEqual(pager.position, 2)
        XCTAssertEqual(pager.count, 4)
        XCTAssertEqual(pager.currentName, "ByBit")
        XCTAssertEqual(pager.previousName, "Наличные")
        XCTAssertEqual(pager.nextName, "Семейный")
        XCTAssertEqual(pager.pages.map(\.id), [Self.cardId, Self.cashId, Self.usdId, Self.familyId], "the carousel's order")
        XCTAssertEqual(pager.widgetKey, key(Self.usdId))
        XCTAssertEqual(pager.configuredAccountId, Self.usdId)
        XCTAssertTrue(pager.forward)
    }

    func test_content_stepOverridesTheConfiguredAccount() throws {
        let overrides = [key(Self.cardId): AccountWidgetOverride(accountId: Self.familyId, forward: false)]
        let c = content(Self.four, configured: Self.cardId, overrides: overrides)
        XCTAssertEqual(c.state.account?.id, Self.familyId)
        let pager = try XCTUnwrap(c.pager)
        XCTAssertEqual(pager.position, 3)
        XCTAssertFalse(pager.forward, "the push comes from the side the user went to")
        XCTAssertEqual(pager.nextName, "Тинькофф", "wraps")
        // Another family of the same account doesn't move with it.
        XCTAssertEqual(content(Self.four, configured: Self.cardId, family: .systemMedium, overrides: overrides).state.account?.id,
                       Self.cardId)
    }

    func test_content_deletedStep_fallsBackToConfigured_thenPrimary() {
        let overrides = [key(Self.cashId): AccountWidgetOverride(accountId: Self.goneId, forward: true)]
        XCTAssertEqual(content(Self.four, configured: Self.cashId, overrides: overrides).state.account?.id, Self.cashId,
                       "a deleted account silently falls back to the configured one")
        let gone = [key(Self.goneId): AccountWidgetOverride(accountId: Self.goneId, forward: true)]
        XCTAssertEqual(content(Self.four, configured: Self.goneId, overrides: gone).state.account?.id, Self.cardId,
                       "configured account deleted too → the primary")
        XCTAssertEqual(content(Self.four, configured: Self.debtId).state.account?.id, Self.cardId,
                       "a «Долги» account is never in the snapshot")
    }

    /// The user edits the widget from the card to cash: the card's step no
    /// longer applies — the widget shows cash.
    func test_content_editedConfiguration_usesItsOwnKey() {
        let overrides = [key(Self.cardId): AccountWidgetOverride(accountId: Self.usdId, forward: true)]
        XCTAssertEqual(content(Self.four, configured: Self.cardId, overrides: overrides).state.account?.id, Self.usdId)
        XCTAssertEqual(content(Self.four, configured: Self.cashId, overrides: overrides).state.account?.id, Self.cashId)
    }

    func test_content_lockScreen_ignoresSteps_andHasNoPager() {
        let overrides = [key(Self.cardId, .accessoryRectangular): AccountWidgetOverride(accountId: Self.usdId, forward: true)]
        let c = content(Self.four, configured: Self.cardId, family: .accessoryRectangular, overrides: overrides)
        XCTAssertEqual(c.state.account?.id, Self.cardId)
        XCTAssertNil(c.pager)
        XCTAssertNil(content(Self.four, configured: Self.cardId, family: .accessoryInline).pager)
    }

    func test_content_singleAccount_hasNoArrows() {
        let c = content(Self.snapshot([Self.card]), configured: Self.cardId)
        XCTAssertEqual(c.state.account?.id, Self.cardId)
        XCTAssertNil(c.pager, "nothing to switch to")
    }

    func test_content_emptyStates() {
        XCTAssertEqual(content(nil, configured: Self.cardId).state, .signedOut)
        XCTAssertNil(content(nil, configured: Self.cardId).pager)
        XCTAssertEqual(content(Self.snapshot(nil), configured: nil).state, .signedOut, "a 1.5.x file")
        XCTAssertEqual(content(Self.snapshot([]), configured: nil).state, .noAccounts)
        // Same answer as the pre-arrows resolver on every family without a step.
        for configured in [Self.cardId, Self.usdId, Self.goneId, nil] {
            XCTAssertEqual(content(Self.four, configured: configured, family: .systemMedium).state,
                           AccountWidgetState.resolve(snapshot: Self.four, accountId: configured))
        }
    }

    // MARK: - Page indicator

    func test_pager_dotsUpToSeven_thenCounter() throws {
        let seven = Self.snapshot((1...7).map { Self.item("0b000000-0000-4000-8000-00000000000\($0)", "A\($0)") })
        let sevenPager = try XCTUnwrap(content(seven, configured: nil).pager)
        XCTAssertTrue(sevenPager.showsDots)
        let nine = Self.snapshot((1...9).map { Self.item("0b000000-0000-4000-8000-00000000000\($0)", "A\($0)") })
        let overrides = [key(nil): AccountWidgetOverride(accountId: "0b000000-0000-4000-8000-000000000003", forward: true)]
        let ninePager = try XCTUnwrap(content(nine, configured: nil, overrides: overrides).pager)
        XCTAssertFalse(ninePager.showsDots)
        XCTAssertEqual(ninePager.counterText, "3/9")
        XCTAssertEqual(AccountWidgetPager.maxDots, 7)
    }

    // MARK: - Step (the intent's state change)

    func test_step_isRelativeToTheStoredState() throws {
        let k = key(Self.cardId)
        var overrides: [String: AccountWidgetOverride] = [:]
        overrides = try XCTUnwrap(AccountWidgetCarousel.step(widgetKey: k, configuredAccountId: Self.cardId, forward: true,
                                                              snapshot: Self.four, overrides: overrides))
        XCTAssertEqual(overrides[k], AccountWidgetOverride(accountId: Self.cashId, forward: true))
        // A second quick tap (before the widget re-rendered) moves on again.
        overrides = try XCTUnwrap(AccountWidgetCarousel.step(widgetKey: k, configuredAccountId: Self.cardId, forward: true,
                                                              snapshot: Self.four, overrides: overrides))
        XCTAssertEqual(overrides[k]?.accountId, Self.usdId)
        overrides = try XCTUnwrap(AccountWidgetCarousel.step(widgetKey: k, configuredAccountId: Self.cardId, forward: false,
                                                              snapshot: Self.four, overrides: overrides))
        XCTAssertEqual(overrides[k], AccountWidgetOverride(accountId: Self.cashId, forward: false))
        XCTAssertEqual(content(Self.four, configured: Self.cardId, overrides: overrides).state.account?.id, Self.cashId,
                       "the provider shows what the intent stored")
    }

    func test_step_wrapsBackwardFromTheConfiguredAccount() throws {
        let k = key(Self.cardId, .systemMedium)
        let overrides = try XCTUnwrap(AccountWidgetCarousel.step(widgetKey: k, configuredAccountId: Self.cardId, forward: false,
                                                                  snapshot: Self.four, overrides: [:]))
        XCTAssertEqual(overrides[k]?.accountId, Self.familyId)
    }

    func test_step_keepsOtherWidgetsSteps_andSkipsDeletedOnes() throws {
        let other = AccountWidgetOverride(accountId: Self.usdId, forward: true)
        let k = key(Self.cashId)
        let start = [key(Self.cardId): other, k: AccountWidgetOverride(accountId: Self.goneId, forward: true)]
        let updated = try XCTUnwrap(AccountWidgetCarousel.step(widgetKey: k, configuredAccountId: Self.cashId, forward: true,
                                                                snapshot: Self.four, overrides: start))
        XCTAssertEqual(updated[key(Self.cardId)], other)
        XCTAssertEqual(updated[k]?.accountId, Self.usdId, "a deleted step starts from the configured account (cash → USD)")
    }

    func test_step_withNothingToSwitchTo_writesNothing() {
        XCTAssertNil(AccountWidgetCarousel.step(widgetKey: key(Self.cardId), configuredAccountId: Self.cardId, forward: true,
                                                snapshot: Self.snapshot([Self.card]), overrides: [:]))
        XCTAssertNil(AccountWidgetCarousel.step(widgetKey: key(nil), configuredAccountId: nil, forward: true,
                                                snapshot: nil, overrides: [:]))
        XCTAssertNil(AccountWidgetCarousel.step(widgetKey: key(nil), configuredAccountId: nil, forward: true,
                                                snapshot: Self.snapshot([]), overrides: [:]))
    }

    func test_stepIntent_carriesThePagersKeyAndConfiguration() throws {
        let pager = try XCTUnwrap(content(Self.four, configured: Self.cashId, family: .systemMedium).pager)
        let next = AccountWidgetStepIntent(pager: pager, forward: true)
        XCTAssertEqual(next.widgetKey, key(Self.cashId, .systemMedium))
        XCTAssertEqual(next.configuredAccountId, Self.cashId)
        XCTAssertTrue(next.forward)
        XCTAssertFalse(AccountWidgetStepIntent(pager: pager, forward: false).forward)
        let unconfigured = try XCTUnwrap(content(Self.four, configured: nil).pager)
        XCTAssertEqual(AccountWidgetStepIntent(pager: unconfigured, forward: true).configuredAccountId, "")
        XCTAssertFalse(AccountWidgetStepIntent.isDiscoverable)
        XCTAssertFalse(AccountWidgetStepIntent.openAppWhenRun, "never opens the app")
    }

    // MARK: - Store and pruning

    func test_store_roundTrip_clear_andGarbage() {
        let defaults = makeDefaults()
        XCTAssertEqual(AccountWidgetOverrideStore.load(from: defaults), [:])
        let overrides = [key(Self.cardId): AccountWidgetOverride(accountId: Self.cashId, forward: false)]
        AccountWidgetOverrideStore.save(overrides, to: defaults)
        XCTAssertEqual(AccountWidgetOverrideStore.load(from: defaults), overrides)
        AccountWidgetOverrideStore.clear(in: defaults)
        XCTAssertEqual(AccountWidgetOverrideStore.load(from: defaults), [:])
        defaults.set(Data("not json".utf8), forKey: AccountWidgetOverrideStore.defaultsKey)
        XCTAssertEqual(AccountWidgetOverrideStore.load(from: defaults), [:], "unreadable → no steps, never a crash")
        AccountWidgetOverrideStore.save([:], to: defaults)
        XCTAssertNil(defaults.object(forKey: AccountWidgetOverrideStore.defaultsKey))
        XCTAssertEqual(AccountWidgetOverrideStore.load(from: nil), [:])
    }

    func test_pruned_dropsRemovedWidgetsAndDeletedAccounts() {
        let live = AccountWidgetOverride(accountId: Self.usdId, forward: true)
        let overrides = [
            key(Self.cardId): live,
            key(Self.cashId): AccountWidgetOverride(accountId: Self.familyId, forward: true),   // widget edited away
            key(Self.usdId): AccountWidgetOverride(accountId: Self.goneId, forward: true),     // account deleted
        ]
        let ids = Set([Self.cardId, Self.cashId, Self.usdId, Self.familyId])
        XCTAssertEqual(AccountWidgetCarousel.pruned(overrides, liveKeys: [key(Self.cardId), key(Self.usdId)], accountIds: ids),
                       [key(Self.cardId): live])
        XCTAssertEqual(AccountWidgetCarousel.pruned(overrides, liveKeys: nil, accountIds: ids).keys.sorted(),
                       [key(Self.cardId), key(Self.cashId)].sorted(), "unknown widgets → only the account check")
    }

    func test_liveKeys_mustIncludeTheWidgetAsking() {
        let own = key(Self.cardId)
        let configurations: [(family: WidgetFamily, configuredAccountId: String?)] = [
            (.systemSmall, Self.cardId), (.systemMedium, Self.cashId), (.accessoryRectangular, Self.usdId),
        ]
        XCTAssertEqual(AccountWidgetCarousel.liveKeys(configurations: configurations, ownKey: own),
                       [own, key(Self.cashId, .systemMedium)], "Lock Screen widgets have no steps")
        XCTAssertNil(AccountWidgetCarousel.liveKeys(configurations: configurations, ownKey: key(Self.familyId)),
                     "an answer without the widget asking is not trusted")
        XCTAssertNil(AccountWidgetCarousel.liveKeys(configurations: [], ownKey: own))
    }

    // MARK: - Deep link: akifi://account?id=

    func test_accountLink_buildAndParse() throws {
        let url = AccountWidgetLinks.account(Self.cashId.uppercased())
        XCTAssertEqual(url.absoluteString, "akifi://account?id=\(Self.cashId)", "lowercased like DB ids")
        XCTAssertEqual(DeepLink.parse(url), .account(id: Self.cashId))
        XCTAssertEqual(AccountWidgetLinks.account("demo-acc-1"), AccountWidgetLinks.home, "a non-UUID id opens Home")
    }

    func test_accountLink_parsing() throws {
        func parse(_ string: String) throws -> DeepLink? { DeepLink.parse(try XCTUnwrap(URL(string: string))) }
        XCTAssertEqual(try parse("akifi://account?id=\(Self.cardId)"), .account(id: Self.cardId))
        XCTAssertEqual(try parse("akifi://account?id=\(Self.cardId.uppercased())"), .account(id: Self.cardId))
        XCTAssertEqual(try parse("AKIFI://ACCOUNT?id=\(Self.cardId)"), .account(id: Self.cardId))
        XCTAssertEqual(try parse("akifi://account?id=\(Self.cardId)&id=\(Self.cashId)"), .account(id: Self.cardId), "first id wins")
        XCTAssertEqual(try parse("akifi://account?id=not-a-uuid"), .tab(.home), "garbage → just Home")
        XCTAssertEqual(try parse("akifi://account?id=%27%3B%20drop"), .tab(.home))
        XCTAssertEqual(try parse("akifi://account?id="), .tab(.home))
        XCTAssertEqual(try parse("akifi://account"), .tab(.home), "missing id → just Home")
        XCTAssertEqual(try parse("akifi://account?account=\(Self.cardId)"), .tab(.home))
        XCTAssertNil(try parse("https://akifi.pro/account?id=\(Self.cardId)"), "only the app scheme")
        XCTAssertEqual(try parse("akifi://home"), .tab(.home), "other links unchanged")
    }

    func test_appViewModel_routesTheAccountLink_andForgetsItOnSignOut() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetCarousel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppViewModel(dataStore: DataStore(cache: PersistenceManager(directory: dir)))
        app.sessionEffects = AppViewModel.SessionEffects(unregisterPushToken: {}, registerPushToken: {}, clearDeviceState: {})
        app.open(AccountWidgetLinks.account(Self.usdId))
        XCTAssertEqual(app.pendingDeepLink, .account(id: Self.usdId), "waits for the signed-in UI (cold start)")
        app.pendingHomeAccountId = Self.usdId
        app.resetForSignOut(preserveQueue: true)
        XCTAssertNil(app.pendingDeepLink)
        XCTAssertNil(app.pendingHomeAccountId, "the next user never lands on it")
    }

    // MARK: - Home carousel mapping

    private static func account(_ id: String, _ name: String, type: AccountType = .checking, primary: Bool = false) -> Account {
        Account(id: id, userId: "u-me", name: name, icon: "💳", color: "#3B82F6", initialBalance: 0,
                isPrimary: primary, currency: "rub", accountType: type)
    }

    func test_homeIndex_forAnAccountId() {
        let accounts = [Self.account(Self.cardId, "Тинькофф", primary: true), Self.account(Self.cashId, "Наличные"),
                        Self.account(Self.usdId, "ByBit")]
        XCTAssertEqual(HomeViewModel.carouselIndex(ofAccount: Self.usdId, in: accounts), 2)
        XCTAssertEqual(HomeViewModel.carouselIndex(ofAccount: Self.cashId.uppercased(), in: accounts), 1)
        XCTAssertNil(HomeViewModel.carouselIndex(ofAccount: Self.goneId, in: accounts))
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.usdId, in: accounts, isLoading: false), .select(2))
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.usdId, in: accounts, isLoading: true), .select(2))
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.goneId, in: accounts, isLoading: false), .ignore)
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.goneId, in: accounts, isLoading: true), .wait,
                       "a load in flight may still bring it")
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.usdId, in: [], isLoading: false), .wait, "cold start: no accounts yet")
    }

    /// A «Долги» account is in `allAccounts` but never in the carousel.
    func test_homeIndex_debtAccountIsIgnored() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetCarousel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DataStore(cache: PersistenceManager(directory: dir))
        store.allAccounts = [Self.account(Self.cardId, "Тинькофф", primary: true), Self.account(Self.debtId, "Маша", type: .debt),
                             Self.account(Self.cashId, "Наличные")]
        XCTAssertEqual(store.accounts.map(\.id), [Self.cardId, Self.cashId])
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.debtId, in: store.accounts, isLoading: false), .ignore)
        XCTAssertEqual(HomeViewModel.outcome(forAccount: Self.cashId, in: store.accounts, isLoading: false), .select(1))
    }

    func test_applyPendingAccount_selectsOrSettles() {
        let model = HomeViewModel()
        let accounts = [Self.account(Self.cardId, "Тинькофф"), Self.account(Self.cashId, "Наличные")]
        XCTAssertFalse(model.applyPendingAccount(Self.cashId, accounts: [], isLoading: true), "keeps waiting")
        XCTAssertEqual(model.selectedAccountIndex, 0)
        XCTAssertTrue(model.applyPendingAccount(Self.cashId, accounts: accounts, isLoading: false))
        XCTAssertEqual(model.selectedAccountIndex, 1)
        XCTAssertEqual(model.selectedAccount(from: accounts)?.id, Self.cashId)
        XCTAssertTrue(model.applyPendingAccount(Self.goneId, accounts: accounts, isLoading: false), "unknown → cleared")
        XCTAssertEqual(model.selectedAccountIndex, 1, "and the selection stays")
    }

    // MARK: - «Все счета»

    private func many(_ count: Int) -> SharedSnapshot {
        Self.snapshot((0..<count).map { Self.item(String(format: "0c000000-0000-4000-8000-%012d", $0), "A\($0)", balance: Int64($0) * 100) })
    }

    private struct NotAccounts: Error {}

    private func content(_ state: AllAccountsWidgetState, line: UInt = #line) throws -> AllAccountsWidgetContent {
        guard case .accounts(let content) = state else {
            XCTFail("not an accounts state: \(state)", line: line)
            throw NotAccounts()
        }
        return content
    }

    func test_allAccounts_limitsAndMore_inOrder() throws {
        XCTAssertEqual(AllAccountsWidgetSelection.limit(for: .systemMedium), 4)
        XCTAssertEqual(AllAccountsWidgetSelection.limit(for: .systemLarge), 8)

        let eleven = many(11)
        let medium = try content(AllAccountsWidgetSelection.state(snapshot: eleven, family: .systemMedium))
        XCTAssertEqual(medium.items.map(\.name), ["A0", "A1", "A2", "A3"], "the app's order")
        XCTAssertEqual(medium.moreCount, 7, "«+7 ещё»")
        let large = try content(AllAccountsWidgetSelection.state(snapshot: eleven, family: .systemLarge))
        XCTAssertEqual(large.items.map(\.name), (0..<8).map { "A\($0)" })
        XCTAssertEqual(large.moreCount, 3)

        let exactlyFour = try content(AllAccountsWidgetSelection.state(snapshot: many(4), family: .systemMedium))
        XCTAssertEqual(exactlyFour.items.count, 4)
        XCTAssertEqual(exactlyFour.moreCount, 0, "no footer when everything fits")
        let one = try content(AllAccountsWidgetSelection.state(snapshot: many(1), family: .systemLarge))
        XCTAssertEqual(one.items.count, 1)
        XCTAssertEqual(one.moreCount, 0)
    }

    func test_allAccounts_emptyStates() {
        XCTAssertEqual(AllAccountsWidgetSelection.state(snapshot: nil, family: .systemMedium), .signedOut)
        XCTAssertEqual(AllAccountsWidgetSelection.state(snapshot: Self.snapshot(nil), family: .systemLarge), .signedOut, "a 1.5.x file")
        XCTAssertEqual(AllAccountsWidgetSelection.state(snapshot: Self.snapshot([]), family: .systemLarge), .noAccounts)
    }

    /// The header shows the snapshot's own base-currency total (the
    /// «Баланс» widget's number) — never a sum of the rows' own currencies.
    func test_allAccounts_totalIsTheSnapshotsBaseTotal() throws {
        var s = Self.snapshot([Self.card, Self.item(Self.usdId, "ByBit", balance: 500_00)])
        s = SharedSnapshot(
            schemaVersion: s.schemaVersion, lastUpdated: s.lastUpdated, baseCurrency: "RUB", baseCurrencySymbol: "₽",
            baseCurrencyDecimals: 0, totalBalance: 46_250_00, accountCount: 2, dailyLimit: nil, dailyLimitBudgetName: nil,
            dailySpentToday: 0, dailyLimitUtilization: 0, currentStreak: 0, nextMilestone: 3, todayIncome: 0,
            todayExpense: 0, todayNet: 0, netWorth: nil, accounts: s.accounts
        )
        let c = try content(AllAccountsWidgetSelection.state(snapshot: s, family: .systemLarge))
        XCTAssertEqual(c.total, 46_250_00)
        XCTAssertEqual(c.totalSymbol, "₽")
        XCTAssertEqual(c.totalDecimals, 0)
        XCTAssertFalse(c.isTotalHidden)
        XCTAssertEqual(c.totalText.filter(\.isNumber), "46250")
    }

    func test_allAccounts_oneHiddenBalanceHidesTheTotal() throws {
        XCTAssertFalse(AllAccountsWidgetSelection.isTotalHidden([Self.card, Self.cash]))
        XCTAssertTrue(AllAccountsWidgetSelection.isTotalHidden([Self.card, Self.item(Self.cashId, "Наличные", hidden: true)]))
        // Hidden on an account past the visible rows still hides the total.
        var accounts = many(9).accounts ?? []
        accounts[8] = Self.item(accounts[8].id, accounts[8].name, hidden: true)
        let c = try content(AllAccountsWidgetSelection.state(snapshot: Self.snapshot(accounts), family: .systemLarge))
        XCTAssertFalse(c.items.contains(where: \.isBalanceHidden))
        XCTAssertTrue(c.isTotalHidden)
        XCTAssertEqual(c.totalText, WidgetMoney.hidden)
        XCTAssertEqual(WidgetMoney.balance(Self.item(Self.cashId, "Наличные", hidden: true)), "••••")
    }

    func test_allAccounts_accessibilityLabel() {
        let shared = SharedSnapshot.AccountItem(id: Self.familyId, name: "Семейный", icon: "👪", colorHex: "#000",
                                                currencyCode: "RUB", currencySymbol: "₽", currencyDecimals: 0, balance: 0,
                                                monthIncome: 0, monthExpense: 0, isPrimary: false, isShared: true,
                                                isBalanceHidden: false)
        XCTAssertTrue(AllAccountsAccessibility.label(Self.card).hasPrefix("Тинькофф, "))
        XCTAssertEqual(AllAccountsAccessibility.label(Self.cash), "Наличные")
        XCTAssertTrue(AllAccountsAccessibility.label(shared).hasPrefix("Семейный, "))
    }

    // MARK: - Reloads

    func test_kindsToReload_allAccountsKind() {
        let base = Self.four
        XCTAssertTrue(AkifiWidgetKind.all.contains(AkifiWidgetKind.accounts))
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: base), [])

        // A balance moved: both account widgets.
        var moved = base
        moved.accounts?[1] = Self.item(Self.cashId, "Наличные", balance: 9_99)
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: moved), [AkifiWidgetKind.account, AkifiWidgetKind.accounts])

        // Only this month's in / out (not on «Все счета»): «Счёт» only.
        var flow = base
        flow.accounts?[0].monthExpense = 123_00
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: flow), [AkifiWidgetKind.account])

        // An account renamed / added / removed / reordered.
        var added = base
        added.accounts?.append(Self.item(Self.goneId, "Новый"))
        XCTAssertTrue(SharedSnapshotWriter.kindsToReload(from: base, to: added).contains(AkifiWidgetKind.accounts))
        var reordered = base
        reordered.accounts?.reverse()
        XCTAssertTrue(SharedSnapshotWriter.kindsToReload(from: base, to: reordered).contains(AkifiWidgetKind.accounts))
    }

    func test_kindsToReload_totalOrBaseCurrency() {
        let base = Self.four
        let total = SharedSnapshot(
            schemaVersion: base.schemaVersion, lastUpdated: base.lastUpdated, baseCurrency: base.baseCurrency,
            baseCurrencySymbol: base.baseCurrencySymbol, baseCurrencyDecimals: base.baseCurrencyDecimals,
            totalBalance: base.totalBalance + 1_00, accountCount: base.accountCount, dailyLimit: base.dailyLimit,
            dailyLimitBudgetName: base.dailyLimitBudgetName, dailySpentToday: base.dailySpentToday,
            dailyLimitUtilization: base.dailyLimitUtilization, currentStreak: base.currentStreak,
            nextMilestone: base.nextMilestone, todayIncome: base.todayIncome, todayExpense: base.todayExpense,
            todayNet: base.todayNet, netWorth: base.netWorth, dayKey: base.dayKey, accounts: base.accounts,
            monthKey: base.monthKey, repeatItems: base.repeatItems
        )
        XCTAssertEqual(SharedSnapshotWriter.kindsToReload(from: base, to: total), [AkifiWidgetKind.balance, AkifiWidgetKind.accounts])

        let usdBase = SharedSnapshot(
            schemaVersion: base.schemaVersion, lastUpdated: base.lastUpdated, baseCurrency: "USD",
            baseCurrencySymbol: "$", baseCurrencyDecimals: 2,
            totalBalance: base.totalBalance, accountCount: base.accountCount, dailyLimit: base.dailyLimit,
            dailyLimitBudgetName: base.dailyLimitBudgetName, dailySpentToday: base.dailySpentToday,
            dailyLimitUtilization: base.dailyLimitUtilization, currentStreak: base.currentStreak,
            nextMilestone: base.nextMilestone, todayIncome: base.todayIncome, todayExpense: base.todayExpense,
            todayNet: base.todayNet, netWorth: base.netWorth, dayKey: base.dayKey, accounts: base.accounts,
            monthKey: base.monthKey, repeatItems: base.repeatItems
        )
        XCTAssertTrue(SharedSnapshotWriter.kindsToReload(from: base, to: usdBase).contains(AkifiWidgetKind.accounts))
    }
}
