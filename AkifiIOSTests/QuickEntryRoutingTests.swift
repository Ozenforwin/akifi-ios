import UIKit
import XCTest
@testable import AkifiIOS

/// Deep links, quick actions, the inbox, the intents' pure support and the
/// host that lends them the app's data store.
@MainActor
final class QuickEntryRoutingTests: XCTestCase {

    private let cafeId = "1a2b3c4d-0000-4000-8000-000000000001"
    private let cardId = "1a2b3c4d-0000-4000-8000-000000000002"

    // MARK: - Links

    func testParsesAFullLink() {
        // As Shortcuts' «Open URL» sends it: fully percent-encoded.
        let url = URL(string: "akifi://quick-add?mode=income&source=siri&text=%2B5000%20%D0%BF%D0%BE%D0%B4%D0%B0%D1%80%D0%BE%D0%BA&amount=12.5&category=\(cafeId.uppercased())&account=\(cardId)&note=%D0%BC%D0%B0%D0%BC%D0%B0")!
        let request = QuickEntryLink.parse(url, now: QE.now)!
        XCTAssertEqual(request.mode, .income)
        XCTAssertEqual(request.source, .siri)
        XCTAssertEqual(request.text, "+5000 подарок")
        XCTAssertEqual(request.amount, Decimal(string: "12.5", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(request.categoryId, cafeId, "lowercased like DB ids")
        XCTAssertEqual(request.accountId, cardId)
        XCTAssertEqual(request.note, "мама")
        XCTAssertEqual(request.transactionType, .income)
        XCTAssertEqual(request.overrides.amount, request.amount)
        XCTAssertEqual(request.overrides.category, .category(cafeId))
    }

    func testDropsWhatItCannotTrust() {
        let url = URL(string: "akifi://quick-add?mode=bogus&amount=-5&category=1;drop&account=x&text=%20%20")!
        let request = QuickEntryLink.parse(url)!
        XCTAssertEqual(request.mode, .expense)
        XCTAssertEqual(request.source, .link)
        XCTAssertNil(request.amount)
        XCTAssertNil(request.categoryId)
        XCTAssertNil(request.accountId)
        XCTAssertNil(request.text)

        let long = String(repeating: "а", count: 500)
        let capped = QuickEntryLink.parse(QuickEntryLink.url(for: QuickEntryRequest(mode: .expense, source: .link, text: long)))!
        XCTAssertEqual(capped.text?.count, QuickEntryLink.maxTextLength)
        XCTAssertNil(QuickEntryLink.parse(URL(string: "akifi://quick-add?amount=1e400")!)?.amount)
    }

    func testOtherURLsAreNotQuickAdd() {
        XCTAssertNil(QuickEntryLink.parse(URL(string: "akifi://home")!))
        XCTAssertNil(QuickEntryLink.parse(URL(string: "https://akifi.pro/quick-add")!))
        XCTAssertNil(QuickEntryLink.parse(URL(string: "other://quick-add")!))
        // And the quick-add host is not a regular deep link either.
        XCTAssertNil(DeepLink.parse(URL(string: "akifi://quick-add")!))
    }

    func testURLRoundTrip() {
        let request = QuickEntryRequest(mode: .voice, source: .control, text: "кофе 300 & такси", amount: 300, categoryId: cafeId, accountId: cardId, note: "n")
        let parsed = QuickEntryLink.parse(QuickEntryLink.url(for: request))!
        XCTAssertEqual(parsed.mode, .voice)
        XCTAssertEqual(parsed.source, .control)
        XCTAssertEqual(parsed.text, "кофе 300 & такси")
        XCTAssertEqual(parsed.amount, 300)
        XCTAssertEqual(parsed.categoryId, cafeId)
        XCTAssertEqual(parsed.accountId, cardId)
        XCTAssertTrue(parsed.startsWithVoice)
        XCTAssertEqual(QuickEntryLaunchURL.make(mode: .expense, source: "control").absoluteString,
                       "akifi://quick-add?mode=expense&source=control")
    }

    func testQuickActionTypes() {
        for mode in QuickEntryLaunchMode.allCases {
            XCTAssertEqual(QuickEntryLink.request(forShortcutType: QuickEntryLink.shortcutType(for: mode))?.mode, mode)
        }
        XCTAssertEqual(QuickEntryLink.request(forShortcutType: "ru.akifi.app.quickEntry.voice")?.source, .quickAction)
        XCTAssertNil(QuickEntryLink.request(forShortcutType: "ru.akifi.app.quickEntry.nope"))
        XCTAssertNil(QuickEntryLink.request(forShortcutType: "com.other.expense"))
    }

    /// The types in project.yml's `UIApplicationShortcutItems` are the ones
    /// the router knows.
    func testInfoPlistQuickActionsAreRouted() throws {
        let items = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems") as? [[String: Any]])
        let types = items.compactMap { $0["UIApplicationShortcutItemType"] as? String }
        XCTAssertEqual(types.count, 3)
        for type in types {
            XCTAssertNotNil(QuickEntryLink.request(forShortcutType: type), type)
        }
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription"))
    }

    // MARK: - Inbox

    func testInboxHoldsOneRequestAndDropsStaleOnes() {
        let inbox = QuickEntryInbox()
        XCTAssertNil(inbox.consume())
        XCTAssertTrue(inbox.open(URL(string: "akifi://quick-add?mode=voice")!, now: QE.now))
        XCTAssertFalse(inbox.open(URL(string: "akifi://home")!))
        XCTAssertEqual(inbox.pending?.mode, .voice)
        XCTAssertEqual(inbox.consume(now: QE.now.addingTimeInterval(5))?.mode, .voice)
        XCTAssertNil(inbox.pending, "consumed")

        XCTAssertTrue(inbox.handleShortcutItem(type: "ru.akifi.app.quickEntry.income", now: QE.now))
        XCTAssertNil(inbox.consume(now: QE.now.addingTimeInterval(QuickEntryInbox.maxAge + 1)), "stale")
        XCTAssertNil(inbox.pending)

        inbox.submit(QuickEntryRequest(mode: .expense, source: .siri))
        inbox.reset()
        XCTAssertNil(inbox.pending)
    }

    func testAppViewModelRoutesQuickAddToTheInbox() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QE-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppViewModel(dataStore: DataStore(cache: PersistenceManager(directory: dir)))
        // No device side effects (widget snapshot, notifications, FCM token).
        app.sessionEffects = AppViewModel.SessionEffects(
            unregisterPushToken: {}, registerPushToken: {}, clearDeviceState: {}
        )
        QuickEntryInbox.shared.reset()
        app.open(URL(string: "akifi://quick-add?mode=income&text=зарплата")!)
        XCTAssertNil(app.pendingDeepLink)
        XCTAssertEqual(QuickEntryInbox.shared.pending?.text, "зарплата")
        app.open(URL(string: "akifi://budgets")!)
        XCTAssertEqual(app.pendingDeepLink, .tab(.budgets), "other links unchanged")
        app.resetForSignOut(preserveQueue: true)
        XCTAssertNil(QuickEntryInbox.shared.pending, "sign-out forgets it")
        XCTAssertTrue(QuickEntryHost.shared.appViewModel === app, "intents borrow this instance")
    }

    /// End to end in the test host: the system → the scene (with the
    /// quick-action delegate class installed) → SwiftUI `onOpenURL` →
    /// `AppViewModel.open` → the inbox. Guards against the custom scene
    /// delegate swallowing URLs.
    func testTheSystemStillDeliversLinksWithTheQuickActionSceneDelegate() async throws {
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("test host not in the foreground")
        }
        QuickEntryInbox.shared.reset()
        let opened = await UIApplication.shared.open(URL(string: "akifi://quick-add?mode=voice&source=link")!)
        XCTAssertTrue(opened)
        for _ in 0..<50 where QuickEntryInbox.shared.pending == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(QuickEntryInbox.shared.pending?.mode, .voice)
        XCTAssertEqual(QuickEntryInbox.shared.pending?.source, .link)
        QuickEntryInbox.shared.reset()
    }

    // MARK: - Host

    func testHostReadiness() async {
        let host = QuickEntryHost()
        if case .failure(let reason) = await host.prepare() { XCTAssertEqual(reason, .notRunning) } else { XCTFail() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QE-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DataStore(cache: PersistenceManager(directory: dir))
        store.currentUserIdProvider = { QE.me }
        let app = AppViewModel(dataStore: store)
        host.attach(app)

        host.sessionUserId = { nil }
        if case .failure(let reason) = await host.prepare() { XCTAssertEqual(reason, .signedOut) } else { XCTFail() }

        host.sessionUserId = { QE.me }
        if case .failure(let reason) = await host.prepare() { XCTAssertEqual(reason, .noData) } else { XCTFail() }

        store.accounts = [QE.card]
        store.categories = [QE.cafe]
        if case .success(let ready) = await host.prepare() { XCTAssertTrue(ready === app) } else { XCTFail() }
        let context = await host.context()
        XCTAssertEqual(context?.accounts.map(\.id), ["acc-card"])
        XCTAssertEqual(context?.displayCategories.map(\.id), ["cat-cafe"])
    }

    // MARK: - Intent support

    func testIntentAmountFromDouble() {
        XCTAssertEqual(QuickEntryIntentSupport.decimal(from: 0.1), Decimal(string: "0.1", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(QuickEntryIntentSupport.decimal(from: 300), 300)
        XCTAssertEqual(QuickEntryIntentSupport.decimal(from: 12.345), Decimal(string: "12.35", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertNil(QuickEntryIntentSupport.decimal(from: 0))
        XCTAssertNil(QuickEntryIntentSupport.decimal(from: -5))
        XCTAssertNil(QuickEntryIntentSupport.decimal(from: .nan))
        XCTAssertNil(QuickEntryIntentSupport.decimal(from: 0.001))
    }

    private var context: QuickEntryContext {
        QE.context(transactions: [
            QE.tx("t1", "кофе", amount: 30000, category: "cat-cafe", account: "acc-cash", raw: "2026-11-26T09:00:00"),
        ])
    }

    func testIntentPlanSavesWithDefaultsAndPrediction() {
        let input = QuickEntryIntentInput(type: .expense, amount: 300, categoryId: nil, accountId: nil, note: "кофе")
        guard case .save(let draft) = QuickEntryIntentSupport.plan(input, context: context, now: QE.now) else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(draft.amount, 300)
        XCTAssertEqual(draft.type, .expense)
        XCTAssertEqual(draft.accountId, "acc-cash")
        XCTAssertEqual(draft.currencyCode, "RUB")
        XCTAssertEqual(draft.categoryId, "cat-cafe")
        XCTAssertEqual(draft.description, "кофе")
        XCTAssertEqual(draft.date, QE.now)
    }

    func testIntentPlanKeepsTheNoteVerbatimAndTheIntentType() {
        // A number or a keyword in the note must not change amount or type.
        let input = QuickEntryIntentInput(type: .expense, amount: 300, categoryId: nil, accountId: "acc-card", note: "2 кофе, зарплата")
        guard case .save(let draft) = QuickEntryIntentSupport.plan(input, context: context, now: QE.now) else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(draft.amount, 300)
        XCTAssertEqual(draft.type, .expense)
        XCTAssertEqual(draft.description, "2 кофе, зарплата")
        XCTAssertEqual(draft.accountId, "acc-card")
    }

    func testIntentPlanDropsACategoryOfTheOtherType() {
        let input = QuickEntryIntentInput(type: .income, amount: 5000, categoryId: "cat-cafe", accountId: nil, note: nil)
        guard case .save(let draft) = QuickEntryIntentSupport.plan(input, context: context, now: QE.now) else {
            return XCTFail("expected a save")
        }
        XCTAssertNotEqual(draft.categoryId, "cat-cafe")
        XCTAssertEqual(draft.type, .income)

        let explicit = QuickEntryIntentInput(type: .expense, amount: 5000, categoryId: "cat-food", accountId: nil, note: "кофе")
        guard case .save(let picked) = QuickEntryIntentSupport.plan(explicit, context: context, now: QE.now) else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(picked.categoryId, "cat-food", "the user's pick beats the prediction")
    }

    func testIntentPlanHandsOverInsteadOfGuessing() {
        let gone = QuickEntryIntentInput(type: .expense, amount: 300, categoryId: nil, accountId: "acc-deleted", note: "кофе")
        guard case .openApp(let request) = QuickEntryIntentSupport.plan(gone, context: context, now: QE.now) else {
            return XCTFail("a deleted account must not be replaced silently")
        }
        XCTAssertEqual(request.amount, 300)
        XCTAssertEqual(request.note, "кофе")
        XCTAssertEqual(request.source, .siri)

        let noAccounts = QE.context(accounts: [QE.deposit])
        let input = QuickEntryIntentInput(type: .income, amount: 300, categoryId: nil, accountId: nil, note: nil)
        guard case .openApp(let incomeRequest) = QuickEntryIntentSupport.plan(input, context: noAccounts, now: QE.now) else {
            return XCTFail("no account to book on")
        }
        XCTAssertEqual(incomeRequest.mode, .income)
    }

    func testIntentTexts() {
        let input = QuickEntryIntentInput(type: .expense, amount: 1234.5, categoryId: nil, accountId: nil, note: "кофе")
        guard case .save(let draft) = QuickEntryIntentSupport.plan(input, context: context, now: QE.now) else {
            return XCTFail("expected a save")
        }
        XCTAssertEqual(QuickEntryIntentSupport.amountText(draft), "1 234\(Locale.current.decimalSeparator ?? ".")5 \(CurrencyCatalog.symbol(for: "RUB"))")
        let saved = QuickEntryIntentSupport.savedText(draft: draft, context: context)
        XCTAssertTrue(saved.contains("Кафе"), saved)
        XCTAssertTrue(saved.contains("Кошелёк"), saved)
        XCTAssertFalse(saved.contains("%"), saved)
        XCTAssertFalse(QuickEntryIntentSupport.largeExpenseText(draft: draft, context: context).contains("%@"))
        XCTAssertFalse(QuickEntryIntentSupport.handOverText(.signedOut).isEmpty)
        XCTAssertEqual(QuickEntryIntentSupport.request(for: input).mode, .expense)
    }

    func testCategoriesMatchingASpokenName() {
        let found = QuickEntryIntentSupport.categories(matching: "кафе", in: [QE.cafe, QE.restaurants, QE.groceries])
        XCTAssertEqual(found.map(\.id).first, "cat-cafe")
        XCTAssertTrue(found.map(\.id).contains("cat-rest"))
        XCTAssertFalse(found.map(\.id).contains("cat-food"))
        XCTAssertEqual(QuickEntryIntentSupport.categories(matching: "", in: [QE.cafe]).count, 1)
    }
}
