import XCTest
@testable import AkifiIOS

/// The quick-entry sheet's model (draft updates, overrides, save, undo),
/// the «+» routing and the inbox hand-over to the sheet.
@MainActor
final class QuickEntrySheetTests: XCTestCase {

    private typealias FakeRecognizer = SpeechQuickEntryTests.FakeRecognizer
    private typealias FakePermissions = SpeechQuickEntryTests.FakePermissions

    @MainActor private final class Counter {
        var value = 0
    }

    // MARK: - Fixtures

    /// «Кофе» was filed under Кафе three times, «Такси» under Такси.
    private var history: [Transaction] {
        [
            QE.tx("t1", "Кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-26T14:10:00"),
            QE.tx("t2", "Такси", amount: 45000, category: "cat-taxi", raw: "2026-11-25T09:00:00"),
            QE.tx("t3", "Кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-24T14:00:00"),
            QE.tx("t4", "Пятёрочка", amount: 124000, category: "cat-food", account: "acc-cash", raw: "2026-11-23T19:00:00"),
            QE.tx("t5", "Кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-20T13:30:00"),
            QE.tx("t6", "Зарплата", amount: 12_000_000, category: "cat-salary", type: .income, raw: "2026-11-15T10:00:00"),
        ]
    }

    private func makeModel(
        request: QuickEntryRequest = QuickEntryRequest(mode: .expense, source: .addButton),
        context: QuickEntryContext? = nil,
        speech: SpeechQuickEntry? = nil
    ) -> QuickEntrySheetModel {
        let store = DataStore(cache: PersistenceManager(directory: tempDir()))
        let model = QuickEntrySheetModel(
            context: context ?? QE.context(transactions: history),
            request: request,
            submitter: QuickEntrySubmitter(dataStore: store, currencyManager: nil),
            speech: speech ?? SpeechQuickEntry(recognizer: FakeRecognizer(), permissions: FakePermissions(), locale: Locale(identifier: "ru-RU")),
            now: { QE.now }
        )
        model.largeExpenseDecision = { _ in nil }
        return model
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QES-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func offlineStore(transactions: [Transaction] = []) -> DataStore {
        let store = DataStore(cache: PersistenceManager(directory: tempDir()))
        store.isConnectedProvider = { false }
        store.allAccounts = [QE.card, QE.cash]
        store.categories = [QE.cafe, QE.groceries, QE.taxi, QE.salary]
        store.transactions = transactions
        store.rebuildCaches()
        return store
    }

    private func fakeTransaction(_ id: String = "saved-1") -> Transaction {
        QE.tx(id, "кофе", amount: 30000, category: "cat-cafe", raw: "2026-11-27T14:30:00")
    }

    // MARK: - Draft updates

    func testTypedPhraseUpdatesTheDraftAndTheLiveLine() {
        let model = makeModel()
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.canSave)

        model.text = "кофе 300"
        XCTAssertEqual(model.draft.amount, 300)
        XCTAssertEqual(model.draft.categoryId, "cat-cafe", "same text before → preselected")
        XCTAssertEqual(model.draft.accountId, "acc-card", "last account used for expenses")
        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(model.canSave)

        let summary = model.summary
        XCTAssertEqual(summary.title, "кофе")
        XCTAssertEqual(summary.amount, QuickEntryIntentSupport.amountText(model.draft))
        XCTAssertEqual(summary.date, String(localized: "date.today").lowercased())
        XCTAssertEqual(summary.account, "Тинькофф")
        XCTAssertEqual(summary.segments.count, 4)
        XCTAssertEqual(model.dateChipLabel, String(localized: "date.today"))
    }

    func testAmountAloneOffersChipsWithoutPreselecting() {
        let model = makeModel()
        model.text = "300"
        XCTAssertTrue(model.canSave)
        XCTAssertNil(model.draft.categoryId, "frequency alone is never confident enough")
        let chips = model.categoryChips
        XCTAssertEqual(chips.first?.category.id, "cat-cafe", "most used first")
        XCTAssertTrue(chips.allSatisfy { $0.category.type == .expense })
        XCTAssertFalse(chips.contains { $0.isSelected })
        XCTAssertNil(model.summary.title)
    }

    func testChipTapCompletesTheEntryOnlyWithAnAmount() {
        let model = makeModel()
        XCTAssertFalse(model.chooseCategory("cat-taxi"), "no amount yet: the tap only picks")
        XCTAssertEqual(model.draft.categoryId, "cat-taxi")
        XCTAssertTrue(model.categoryChips.first { $0.category.id == "cat-taxi" }?.isSelected ?? false)

        model.text = "450"
        XCTAssertEqual(model.draft.categoryId, "cat-taxi", "the pick survives typing")
        XCTAssertTrue(model.chooseCategory("cat-taxi"), "amount → category = done")
        XCTAssertEqual(model.summary.title, "Такси", "no description: the category names it")

        model.clearCategory()
        XCTAssertNil(model.draft.categoryId)
        XCTAssertEqual(model.overrides.category, QuickEntryOverrides.CategoryChoice.none)
    }

    func testChipRowIsCappedAndAPickFromTheFullListLeadsIt() {
        let extra = (1...8).map { QE.category("cat-x\($0)", "Категория \($0)") }
        let categories = [QE.cafe, QE.groceries, QE.taxi, QE.salary] + extra
        let model = makeModel(context: QE.context(categories: categories, transactions: history))
        XCTAssertEqual(model.categoryChips.count, QuickEntrySheetModel.chipCount)
        XCTAssertFalse(model.categoryChips.contains { $0.category.id == "cat-x8" })

        model.chooseCategory("cat-x8")
        XCTAssertEqual(model.categoryChips.first?.category.id, "cat-x8")
        XCTAssertTrue(model.categoryChips.first?.isSelected ?? false)
        XCTAssertEqual(model.categoryChips.count, QuickEntrySheetModel.chipCount)
        XCTAssertEqual(model.categoriesForType.count, 3 + extra.count)
    }

    func testTypeSwitchPinsTheTypeAndDropsTheOtherTypesCategory() {
        let model = makeModel()
        model.text = "300"
        model.chooseCategory("cat-cafe")
        model.setType(.income)
        XCTAssertEqual(model.draft.type, .income)
        XCTAssertNotEqual(model.draft.categoryId, "cat-cafe")
        XCTAssertEqual(model.overrides.category, .automatic, "prediction for the new type")
        XCTAssertTrue(model.categoryChips.allSatisfy { $0.category.type == .income })

        model.text = "-300"
        XCTAssertEqual(model.draft.type, .income, "the user's choice beats the sign")

        model.setType(.transfer)
        XCTAssertEqual(model.draft.type, .income, "transfers stay in the transfer form")
    }

    func testIncomeModeFromTheRequest() {
        let model = makeModel(request: QuickEntryRequest(mode: .income, source: .quickAction))
        model.text = "5000"
        XCTAssertEqual(model.draft.type, .income)
        model.text = "-5000"
        XCTAssertEqual(model.draft.type, .expense, "the mode is a default, the phrase can say otherwise")
    }

    func testAccountAndDateOverrides() {
        let model = makeModel()
        model.text = "кофе 300"
        model.chooseAccount("acc-cash")
        XCTAssertEqual(model.draft.accountId, "acc-cash")
        XCTAssertEqual(model.summary.account, "Кошелёк")
        model.chooseAccount("acc-gone")
        XCTAssertEqual(model.draft.accountId, "acc-cash", "unknown ids are ignored")

        model.chooseDay(offset: -1)
        XCTAssertEqual(model.dateChipLabel, String(localized: "date.yesterday"))
        XCTAssertEqual(model.summary.date, String(localized: "date.yesterday").lowercased())
        XCTAssertEqual(QE.calendar.component(.hour, from: model.draft.date), 14, "keeps the time of day")
        XCTAssertEqual(QE.calendar.component(.day, from: model.draft.date), 26)

        model.chooseDate(QE.date(2026, 11, 12))
        XCTAssertEqual(QE.calendar.component(.day, from: model.draft.date), 12)
        XCTAssertNotEqual(model.dateChipLabel, String(localized: "date.today"))
    }

    // MARK: - Repeat

    func testRepeatFillsTheDraftAndEditingHandsBackToThePhrase() throws {
        let model = makeModel()
        XCTAssertTrue(model.showsRepeatStrip)
        let coffee = try XCTUnwrap(model.repeatCandidates.first { $0.description == "Кофе" })
        XCTAssertTrue(model.repeatCandidates.allSatisfy { $0.type == .expense })

        model.applyRepeat(coffee)
        XCTAssertEqual(model.appliedRepeatId, coffee.id)
        XCTAssertEqual(model.text, "Кофе 300")
        XCTAssertEqual(model.draft.amount, 300)
        XCTAssertEqual(model.draft.description, "Кофе")
        XCTAssertEqual(model.draft.categoryId, "cat-cafe")
        XCTAssertEqual(model.draft.accountId, "acc-card")
        XCTAssertEqual(model.draft.currencyCode, "RUB")
        XCTAssertNil(model.overrides.currencyCode, "own currency follows the account")
        XCTAssertTrue(model.showsRepeatStrip, "stays while the repeat is applied")
        XCTAssertTrue(model.canSave)

        model.text = "Кофе 350"
        XCTAssertNil(model.appliedRepeatId)
        XCTAssertEqual(model.draft.amount, 350, "the phrase rules again")
        XCTAssertEqual(model.draft.categoryId, "cat-cafe", "the chips the user saw stay")
        XCTAssertEqual(model.draft.accountId, "acc-card")
        XCTAssertFalse(model.showsRepeatStrip)
    }

    func testRepeatInAForeignCurrencyKeepsIt() throws {
        let rows = [QE.tx("f1", "Netflix", amount: 110000, category: "cat-cafe", raw: "2026-11-26T10:00:00",
                          foreignAmount: 12, foreignCurrency: "USD")]
        let model = makeModel(context: QE.context(transactions: rows))
        let item = try XCTUnwrap(model.repeatCandidates.first)
        model.applyRepeat(item)
        XCTAssertEqual(model.text, "Netflix 12 USD")
        XCTAssertEqual(model.draft.currencyCode, "USD")
        XCTAssertEqual(model.draft.amount, 12)
        XCTAssertEqual(model.formPrefill.currencyCode, "USD", "the form keeps the foreign entry")
    }

    func testRepeatStripFollowsTheType() {
        let model = makeModel()
        model.setType(.income)
        XCTAssertEqual(model.repeatCandidates.map(\.description), ["Зарплата"])
    }

    // MARK: - Seeds (links, Siri hand-over)

    func testPlainPhraseIsTypedIn() {
        let model = makeModel(request: QuickEntryRequest(mode: .expense, source: .link, text: "такси 450"))
        XCTAssertEqual(model.text, "такси 450")
        XCTAssertEqual(model.draft.amount, 450)
        XCTAssertEqual(model.draft.categoryId, "cat-taxi")
        model.text = "такси 500"
        XCTAssertEqual(model.draft.amount, 500)
    }

    func testSiriHandOverShowsItsAmountAndNoteAsAPhrase() {
        let request = QuickEntryRequest(mode: .expense, source: .siri, amount: 300, categoryId: "cat-cafe", note: "латте")
        let model = makeModel(request: request)
        XCTAssertEqual(model.text, "латте 300")
        XCTAssertEqual(model.draft.amount, 300)
        XCTAssertEqual(model.draft.description, "латте")
        XCTAssertEqual(model.draft.categoryId, "cat-cafe")

        model.text = "латте 250"
        XCTAssertEqual(model.draft.amount, 250, "editing hands the amount back to the phrase")
        XCTAssertEqual(model.draft.description, "латте")
        XCTAssertEqual(model.draft.categoryId, "cat-cafe")
    }

    func testSeedHelpers() {
        XCTAssertEqual(QuickEntrySheetModel.phrase(description: " Кофе ", amount: 300, currency: nil), "Кофе 300")
        XCTAssertEqual(QuickEntrySheetModel.phrase(description: "", amount: Decimal(string: "12.5")!, currency: "usd"), "12.5 USD")
        let seed = QuickEntrySheetModel.seed(for: QuickEntryRequest(mode: .expense, source: .link, text: "кофе 300", amount: 999))
        XCTAssertEqual(seed.text, "кофе 300", "a phrase with its own amount isn't extended")
        XCTAssertTrue(seed.hasPrefilledOverrides)
        XCTAssertEqual(seed.overrides.amount, 999)
        XCTAssertFalse(QuickEntrySheetModel.seed(for: QuickEntryRequest(mode: .voice, source: .control)).hasPrefilledOverrides)
    }

    func testFormPrefillCarriesTheDraft() {
        let model = makeModel()
        model.text = "кофе 300 вчера"
        let prefill = model.formPrefill
        XCTAssertEqual(prefill.type, .expense)
        XCTAssertEqual(prefill.amount, 300)
        XCTAssertNil(prefill.currencyCode, "account currency: the form follows the account")
        XCTAssertEqual(prefill.accountId, "acc-card")
        XCTAssertEqual(prefill.categoryId, "cat-cafe")
        XCTAssertEqual(prefill.description, "кофе")
        XCTAssertEqual(QE.calendar.component(.day, from: prefill.date), 26)

        model.text = "€20 netflix"
        XCTAssertEqual(model.formPrefill.currencyCode, "EUR")
    }

    // MARK: - Voice

    func testDictationGoesAfterWhatIsTyped() async {
        let recognizer = FakeRecognizer()
        let speech = SpeechQuickEntry(recognizer: recognizer, permissions: FakePermissions(), locale: Locale(identifier: "ru-RU"))
        let model = makeModel(speech: speech)
        model.text = "кофе"
        await model.startVoice()
        XCTAssertEqual(model.voiceStatus, .listening)
        XCTAssertFalse(recognizer.lastContextualStrings.isEmpty, "names help the recognizer")

        model.applyTranscript("триста")
        XCTAssertEqual(model.text, "кофе триста")
        XCTAssertEqual(model.draft.amount, 300)
        model.finishVoice("триста")
        XCTAssertEqual(model.text, "кофе триста")

        model.applyTranscript("ещё")
        XCTAssertEqual(model.text, "кофе триста", "after the dictation nothing more is appended")
        model.cancelVoice()
    }

    func testDeniedMicrophoneFallsBackToTyping() async {
        let permissions = FakePermissions()
        permissions.mic = false
        let speech = SpeechQuickEntry(recognizer: FakeRecognizer(), permissions: permissions, locale: Locale(identifier: "ru-RU"))
        let model = makeModel(speech: speech)
        await model.startVoice()
        XCTAssertEqual(model.voiceStatus, .deniedMicrophone)
        XCTAssertTrue(model.voiceStatus?.offersSettings ?? false)
        XCTAssertTrue(model.voiceStatus?.fallsBackToTyping ?? false)
        model.applyTranscript("кофе")
        XCTAssertEqual(model.text, "", "nothing is fed after a refusal")
    }

    func testUnavailableRecognizerFallsBackToTyping() async {
        let recognizer = FakeRecognizer()
        recognizer.available = false
        let speech = SpeechQuickEntry(recognizer: recognizer, permissions: FakePermissions(), locale: Locale(identifier: "ru-RU"))
        let model = makeModel(speech: speech)
        await model.startVoice()
        XCTAssertEqual(model.voiceStatus, .unavailable)
        XCTAssertFalse(model.voiceStatus?.offersSettings ?? true)
        XCTAssertTrue(model.voiceStatus?.fallsBackToTyping ?? false)
    }

    func testVoiceStatusMapping() {
        XCTAssertNil(QuickEntryVoiceStatus(.idle))
        XCTAssertNil(QuickEntryVoiceStatus(.finished("кофе")))
        XCTAssertEqual(QuickEntryVoiceStatus(.finishing), .listening)
        XCTAssertEqual(QuickEntryVoiceStatus(.denied(.speech)), .deniedSpeech)
        XCTAssertEqual(QuickEntryVoiceStatus(.denied(.restricted)), .restricted)
        XCTAssertEqual(QuickEntryVoiceStatus(.failed("x")), .failed)
        XCTAssertFalse(QuickEntryVoiceStatus.requestingPermission.fallsBackToTyping)
    }

    // MARK: - Save and undo

    func testSaveGoesThroughTheSubmitterAndUndoDeletesThroughTheStore() async throws {
        let store = offlineStore(transactions: history)
        var submitter = QuickEntrySubmitter(dataStore: store, currencyManager: nil)
        submitter.userId = { "u-live" }
        let coordinator = QuickEntryCoordinator()
        coordinator.makeSpeech = { SpeechQuickEntry(recognizer: FakeRecognizer(), permissions: FakePermissions()) }
        coordinator.configureSubmitter = { $0.userId = { "u-live" } }
        coordinator.present(QuickEntryRequest(mode: .expense, source: .addButton), dataStore: store, currencyManager: nil)
        let model = try XCTUnwrap(coordinator.presented?.model)
        model.largeExpenseDecision = { _ in nil }

        model.text = "кофе 300"
        let outcome = await model.save()
        guard case .saved(let saved) = outcome else { return XCTFail("expected a save, got \(outcome)") }
        XCTAssertEqual(saved.transaction.amountNative, 30000)
        XCTAssertEqual(saved.transaction.categoryId, "cat-cafe")
        XCTAssertEqual(saved.method, .text)
        XCTAssertTrue(saved.label.hasPrefix("кофе "))
        XCTAssertTrue(saved.toastText.contains(saved.label))
        XCTAssertTrue(store.transactions.contains { $0.id == saved.transaction.id })
        XCTAssertTrue(store.offlineQueue.hasPending, "offline: queued like any create")
        XCTAssertFalse(model.isSaving)

        coordinator.didSave(saved)
        XCTAssertNil(coordinator.presented, "the sheet closes")
        XCTAssertEqual(coordinator.toast, saved)

        let undone = await coordinator.undo(saved, dataStore: store)
        XCTAssertTrue(undone)
        XCTAssertNil(coordinator.toast)
        XCTAssertFalse(store.transactions.contains { $0.id == saved.transaction.id })
        XCTAssertFalse(store.offlineQueue.hasPending, "the queued create is cancelled, nothing reaches the server")
        let again = await coordinator.undo(saved, dataStore: store)
        XCTAssertFalse(again, "already gone")
    }

    func testRepeatAndVoiceSavesAreTold() async throws {
        let model = makeModel()
        let transaction = fakeTransaction()
        model.submit = { _ in transaction }
        model.applyRepeat(try XCTUnwrap(model.repeatCandidates.first))
        guard case .saved(let saved) = await model.save() else { return XCTFail("not saved") }
        XCTAssertEqual(saved.method, .repeat)
    }

    func testLargeExpenseAsksFirst() async {
        let model = makeModel()
        let submits = Counter()
        let transaction = fakeTransaction()
        model.submit = { _ in submits.value += 1; return transaction }
        let decision = TransactionGuards.LargeExpenseDecision(shouldConfirm: true, medianInBaseDisplay: 300, inputInBaseDisplay: 90_000)
        model.largeExpenseDecision = { _ in decision }
        model.text = "кофе 90000"

        let first = await model.save()
        XCTAssertEqual(first, .needsLargeExpenseConfirmation(decision))
        XCTAssertEqual(submits.value, 0)

        guard case .saved = await model.save(confirmingLargeExpense: true) else { return XCTFail("not saved") }
        XCTAssertEqual(submits.value, 1)
    }

    func testSaveFailureStaysOnTheSheet() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let model = makeModel()
        model.submit = { _ in throw Boom() }
        model.text = "кофе 300"
        let outcome = await model.save()
        XCTAssertEqual(outcome, .failed("boom"))
        XCTAssertEqual(model.errorMessage, "boom")
        XCTAssertFalse(model.isSaving)
        XCTAssertTrue(model.canSave, "can try again")
    }

    func testNothingToSaveWithoutAnAmountOrAnAccount() async {
        let model = makeModel()
        model.text = "кофе"
        let outcome = await model.save()
        XCTAssertEqual(outcome, .notReady)

        let noAccounts = makeModel(context: QE.context(accounts: [], transactions: []))
        noAccounts.text = "300"
        XCTAssertFalse(noAccounts.canSave)
        XCTAssertNil(noAccounts.account)
    }

    func testContextRefreshKeepsThePhraseAndChoices() {
        let model = makeModel(context: QE.context(transactions: []))
        model.text = "кофе 300"
        XCTAssertNil(model.draft.categoryId)
        model.chooseAccount("acc-cash")
        model.updateContext(QE.context(transactions: history))
        XCTAssertEqual(model.draft.categoryId, "cat-cafe", "the history arrived")
        XCTAssertEqual(model.draft.accountId, "acc-cash")
        XCTAssertEqual(model.text, "кофе 300")
    }

    // MARK: - «+» routing

    func testTapOpensQuickEntryForAnExpense() {
        XCTAssertEqual(FABMenu.tapAction, .expense())
        XCTAssertEqual(
            QuickEntryCoordinator.route(FABMenu.tapAction, selectedTab: .analytics, contextAccountId: nil, accounts: [QE.card]),
            .quickEntry(mode: .expense, categoryId: nil, accountId: nil)
        )
    }

    func testLongPressMenu() {
        XCTAssertEqual(FABMenu.items().map(\.id), ["income", "expense", "transfer", "receipt", "debt.lend", "debt.borrow"])
        XCTAssertEqual(FABMenu.items().last?.label, DebtAction.borrow.title)

        let accounts = [QE.card, QE.cash]
        func route(_ action: FABAction) -> FABRoute {
            QuickEntryCoordinator.route(action, selectedTab: .transactions, contextAccountId: nil, accounts: accounts)
        }
        XCTAssertEqual(route(.income()), .quickEntry(mode: .income, categoryId: nil, accountId: nil))
        XCTAssertEqual(route(.expense()), .quickEntry(mode: .expense, categoryId: nil, accountId: nil))
        XCTAssertEqual(route(.expense(categoryId: "cat-cafe")), .quickEntry(mode: .expense, categoryId: "cat-cafe", accountId: nil))
        XCTAssertEqual(route(.transfer), .transfer)
        XCTAssertEqual(route(.receipt), .receipt)
        XCTAssertEqual(route(.debt(.lend)), .debt(.lend))
        XCTAssertEqual(route(.debt(.borrow)), .debt(.borrow))
    }

    func testContextualAccountCountsOnlyWhenItIsAChoice() {
        let accounts = [QE.card, QE.cash]
        XCTAssertNil(QuickEntryCoordinator.pinnedAccountId(selectedTab: .home, contextAccountId: "acc-card", accounts: accounts),
                     "the carousel at rest: quick entry's own default")
        XCTAssertEqual(QuickEntryCoordinator.pinnedAccountId(selectedTab: .home, contextAccountId: "acc-cash", accounts: accounts), "acc-cash")
        XCTAssertNil(QuickEntryCoordinator.pinnedAccountId(selectedTab: .budgets, contextAccountId: "acc-cash", accounts: accounts))
        XCTAssertNil(QuickEntryCoordinator.pinnedAccountId(selectedTab: .home, contextAccountId: "acc-gone", accounts: accounts))
        XCTAssertNil(QuickEntryCoordinator.pinnedAccountId(selectedTab: .home, contextAccountId: nil, accounts: accounts))
        XCTAssertEqual(
            QuickEntryCoordinator.route(.expense(), selectedTab: .home, contextAccountId: "acc-cash", accounts: accounts),
            .quickEntry(mode: .expense, categoryId: nil, accountId: "acc-cash")
        )
    }

    func testPinnedAccountBecomesTheSheetsAccount() {
        let request = QuickEntryRequest(mode: .expense, source: .addButton, accountId: "acc-cash")
        let model = makeModel(request: request)
        model.text = "кофе 300"
        XCTAssertEqual(model.draft.accountId, "acc-cash")
        XCTAssertEqual(model.draft.accountSource, .user)
    }

    // MARK: - Inbox

    func testInboxRequestIsTakenOnce() {
        let inbox = QuickEntryInbox()
        let coordinator = QuickEntryCoordinator()
        XCTAssertNil(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: false))

        let request = QuickEntryRequest(mode: .voice, source: .quickAction, createdAt: QE.now)
        inbox.submit(request)
        XCTAssertEqual(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: false, now: QE.now)?.id, request.id)
        XCTAssertNil(inbox.pending)
        XCTAssertNil(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: false, now: QE.now))
    }

    func testInboxRequestWaitsForAnotherSheet() {
        let inbox = QuickEntryInbox()
        let coordinator = QuickEntryCoordinator()
        let request = QuickEntryRequest(mode: .expense, source: .control, createdAt: QE.now)
        inbox.submit(request)
        XCTAssertNil(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: true, now: QE.now))
        XCTAssertEqual(inbox.pending?.id, request.id, "still waiting")
        XCTAssertEqual(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: false, now: QE.now)?.id, request.id)
    }

    func testStaleInboxRequestIsDropped() {
        let inbox = QuickEntryInbox()
        let coordinator = QuickEntryCoordinator()
        inbox.submit(QuickEntryRequest(mode: .expense, source: .siri, createdAt: QE.now.addingTimeInterval(-QuickEntryInbox.maxAge - 1)))
        XCTAssertNil(coordinator.takeInboxRequest(from: inbox, otherSheetPresented: false, now: QE.now))
        XCTAssertNil(inbox.pending)
    }

    func testPresentedRequestBecomesTheSheet() throws {
        let store = offlineStore(transactions: history)
        let coordinator = QuickEntryCoordinator()
        let speeches = Counter()
        coordinator.makeSpeech = {
            speeches.value += 1
            return SpeechQuickEntry(recognizer: FakeRecognizer(), permissions: FakePermissions())
        }
        coordinator.present(QuickEntryRequest(mode: .voice, source: .siri, text: "такси 450"), dataStore: store, currencyManager: nil)
        let model = try XCTUnwrap(coordinator.presented?.model)
        XCTAssertTrue(model.startsWithVoice)
        XCTAssertEqual(model.source, .siri)
        XCTAssertEqual(model.text, "такси 450")
        XCTAssertEqual(model.draft.amount, 450)
        XCTAssertEqual(speeches.value, 1)

        // A second request replaces the open sheet.
        coordinator.present(QuickEntryRequest(mode: .income, source: .link), dataStore: store, currencyManager: nil)
        XCTAssertFalse(try XCTUnwrap(coordinator.presented?.model).startsWithVoice)
        XCTAssertEqual(coordinator.presented?.model.draft.type, .income)
    }

    func testDetailsHandOverOpensTheFormAfterTheSheet() throws {
        let store = offlineStore(transactions: history)
        let coordinator = QuickEntryCoordinator()
        coordinator.makeSpeech = { SpeechQuickEntry(recognizer: FakeRecognizer(), permissions: FakePermissions()) }
        XCTAssertNil(coordinator.takePendingDetails())
        coordinator.present(QuickEntryRequest(mode: .expense, source: .addButton, text: "кофе 300"), dataStore: store, currencyManager: nil)

        coordinator.openDetails()
        XCTAssertNil(coordinator.presented)
        let prefill = try XCTUnwrap(coordinator.takePendingDetails())
        XCTAssertEqual(prefill.amount, 300)
        XCTAssertEqual(prefill.categoryId, "cat-cafe")
        XCTAssertNil(coordinator.takePendingDetails(), "once")
    }

    func testToastDismissMatchesItsEntry() {
        let coordinator = QuickEntryCoordinator()
        let saved = QuickEntrySaved(transaction: fakeTransaction(), label: "кофе 300 ₽", method: .text)
        coordinator.didSave(saved)
        coordinator.dismissToast(id: UUID())
        XCTAssertEqual(coordinator.toast, saved, "another toast's timer doesn't close this one")
        coordinator.dismissToast(id: saved.id)
        XCTAssertNil(coordinator.toast)
    }

    func testDayLabels() {
        let today = String(localized: "date.today")
        XCTAssertEqual(QuickEntrySheetModel.dayLabel(QE.now, now: QE.now, calendar: QE.calendar, capitalized: true), today)
        XCTAssertEqual(QuickEntrySheetModel.dayLabel(QE.now, now: QE.now, calendar: QE.calendar, capitalized: false), today.lowercased())
        XCTAssertEqual(
            QuickEntrySheetModel.dayLabel(QE.date(2026, 11, 26, 1), now: QE.now, calendar: QE.calendar, capitalized: true),
            String(localized: "date.yesterday")
        )
        XCTAssertEqual(
            QuickEntrySheetModel.dayLabel(QE.date(2026, 11, 2), now: QE.now, calendar: QE.calendar, capitalized: true),
            AppDateFormatters.dayMonth.string(from: QE.date(2026, 11, 2))
        )
        XCTAssertEqual(
            QuickEntrySheetModel.dayLabel(QE.date(2025, 3, 2), now: QE.now, calendar: QE.calendar, capitalized: true),
            AppDateFormatters.dayMonthYear.string(from: QE.date(2025, 3, 2))
        )
    }
    // MARK: - Device feedback 2026-11-28 (currency chip, «Перевод»)

    func testCurrencyChipSetsTheAmountCurrencyAndSurvivesEditing() {
        let model = makeModel()
        model.text = "кофе 300"
        XCTAssertEqual(model.draft.currencyCode, "RUB")
        XCTAssertEqual(model.entryCurrency?.code, "RUB")

        model.chooseCurrency("usd")
        XCTAssertEqual(model.draft.currencyCode, "USD")
        XCTAssertEqual(model.draft.amount, 300)

        model.text = "кофе 350"
        XCTAssertEqual(model.draft.currencyCode, "USD", "the chosen currency stays while the phrase changes")
        XCTAssertEqual(model.draft.amount, 350)
    }

    func testCurrencyChipWinsOverTheCurrencyInThePhrase() {
        let model = makeModel()
        model.text = "обед 12$"
        XCTAssertEqual(model.draft.currencyCode, "USD")
        model.chooseCurrency("RUB")
        XCTAssertEqual(model.draft.currencyCode, "RUB")
    }

    func testCurrencyChipSurvivesEditingARepeatedEntry() throws {
        let model = makeModel()
        let item = try XCTUnwrap(model.repeatCandidates.first)
        model.applyRepeat(item)
        model.chooseCurrency("EUR")
        model.text = model.text + "0"
        XCTAssertEqual(model.draft.currencyCode, "EUR")
    }

    func testTransferHandOverOpensTheTransferFormAfterTheSheet() {
        let store = offlineStore(transactions: history)
        let coordinator = QuickEntryCoordinator()
        coordinator.makeSpeech = { SpeechQuickEntry(recognizer: FakeRecognizer(), permissions: FakePermissions()) }
        XCTAssertFalse(coordinator.takePendingTransfer())
        coordinator.present(QuickEntryRequest(mode: .expense, source: .addButton), dataStore: store, currencyManager: nil)

        coordinator.openTransfer()
        XCTAssertNil(coordinator.presented)
        XCTAssertNil(coordinator.takePendingDetails(), "a transfer is not the full form")
        XCTAssertTrue(coordinator.takePendingTransfer())
        XCTAssertFalse(coordinator.takePendingTransfer(), "once")
    }

    func testTransferWithoutAnOpenSheetDoesNothing() {
        let coordinator = QuickEntryCoordinator()
        coordinator.openTransfer()
        XCTAssertFalse(coordinator.takePendingTransfer())
    }
}
