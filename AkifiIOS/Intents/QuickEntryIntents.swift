import AppIntents
import Foundation

// MARK: - Siri / Shortcuts: add an expense or an income

/// «Добавь расход в Акифи» → Siri asks for the amount → saved.
///
/// Runs in the app process (background launch when needed) and writes
/// through the app's own `DataStore` via `QuickEntrySubmitter` — the same
/// path as the quick-entry sheet and the form (session check, ADR-001
/// fields, offline queue). When it can't (signed out, nothing loaded yet,
/// a named account that no longer exists) it hands over to the app with
/// the quick-entry sheet prefilled instead of guessing.
///
/// `requiresAuthentication`: never from a locked phone — it's money, and
/// the session lives in the keychain.
struct AddExpenseIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "quickEntry.intent.addExpense.title"
    static let description = IntentDescription("quickEntry.intent.addExpense.description")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    @Parameter(title: "quickEntry.intent.amount", requestValueDialog: "quickEntry.intent.amount.request")
    var amount: Double

    @Parameter(title: "quickEntry.intent.category", optionsProvider: QuickEntryExpenseCategoryOptions())
    var category: QuickEntryCategoryEntity?

    @Parameter(title: "quickEntry.intent.note")
    var note: String?

    @Parameter(title: "quickEntry.intent.account")
    var account: QuickEntryAccountEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let value = QuickEntryIntentSupport.decimal(from: amount) else {
            throw $amount.needsValueError("quickEntry.intent.amount.request")
        }
        let dialog = try await QuickEntryIntentPerformer.run(
            self,
            input: QuickEntryIntentInput(type: .expense, amount: value, categoryId: category?.id, accountId: account?.id, note: note)
        )
        return .result(dialog: dialog)
    }
}

/// «Добавь доход в Акифи».
struct AddIncomeIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "quickEntry.intent.addIncome.title"
    static let description = IntentDescription("quickEntry.intent.addIncome.description")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    @Parameter(title: "quickEntry.intent.amount", requestValueDialog: "quickEntry.intent.amount.request")
    var amount: Double

    @Parameter(title: "quickEntry.intent.category", optionsProvider: QuickEntryIncomeCategoryOptions())
    var category: QuickEntryCategoryEntity?

    @Parameter(title: "quickEntry.intent.note")
    var note: String?

    @Parameter(title: "quickEntry.intent.account")
    var account: QuickEntryAccountEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let value = QuickEntryIntentSupport.decimal(from: amount) else {
            throw $amount.needsValueError("quickEntry.intent.amount.request")
        }
        let dialog = try await QuickEntryIntentPerformer.run(
            self,
            input: QuickEntryIntentInput(type: .income, amount: value, categoryId: category?.id, accountId: account?.id, note: note)
        )
        return .result(dialog: dialog)
    }
}

/// «Голосовой ввод в Акифи» — opens the app straight into dictation.
struct StartVoiceEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "quickEntry.intent.voice.title"
    static let description = IntentDescription("quickEntry.intent.voice.description")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickEntryInbox.shared.submit(QuickEntryRequest(mode: .voice, source: .siri))
        return .result()
    }
}

// MARK: - Shared perform

@MainActor
enum QuickEntryIntentPerformer {

    /// Saves `input` or hands over to the app. Returns Siri's answer.
    static func run<Intent: ForegroundContinuableIntent>(_ intent: Intent, input: QuickEntryIntentInput) async throws -> IntentDialog {
        switch await QuickEntryHost.shared.prepare() {
        case .failure(let reason):
            let request = QuickEntryIntentSupport.request(for: input)
            throw intent.needsToContinueInForegroundError(
                IntentDialog(stringLiteral: QuickEntryIntentSupport.handOverText(reason))
            ) {
                QuickEntryInbox.shared.submit(request)
            }
        case .success(let app):
            let context = QuickEntryContext(dataStore: app.dataStore, currencyManager: app.currencyManager)
            switch QuickEntryIntentSupport.plan(input, context: context) {
            case .openApp(let request):
                throw intent.needsToContinueInForegroundError(
                    IntentDialog(stringLiteral: QuickEntryIntentSupport.handOverText(.noData))
                ) {
                    QuickEntryInbox.shared.submit(request)
                }
            case .save(let draft):
                let submitter = QuickEntrySubmitter(dataStore: app.dataStore, currencyManager: app.currencyManager)
                if let decision = submitter.largeExpenseDecision(for: draft), decision.shouldConfirm {
                    try await intent.requestConfirmation(
                        actionName: .add,
                        dialog: IntentDialog(stringLiteral: QuickEntryIntentSupport.largeExpenseText(draft: draft, context: context))
                    )
                }
                try await submitter.submit(draft)
                // A background launch may be suspended right after this:
                // land the cache and widget snapshot now.
                app.dataStore.flushPendingWrites()
                return IntentDialog(stringLiteral: QuickEntryIntentSupport.savedText(draft: draft, context: context))
            }
        }
    }
}

// MARK: - Pure support (tested)

struct QuickEntryIntentInput: Equatable, Sendable {
    let type: TransactionType
    /// Main units of the account currency.
    let amount: Decimal
    let categoryId: String?
    let accountId: String?
    let note: String?
}

enum QuickEntryIntentPlan: Equatable {
    case save(QuickEntryDraft)
    case openApp(QuickEntryRequest)
}

enum QuickEntryIntentSupport {

    /// Siri hands a `Double`; `Decimal(0.1)` is 0.1000000000000000055…,
    /// the shortest description is what was said. Nil for ≤ 0 / NaN.
    static func decimal(from value: Double) -> Decimal? {
        guard value.isFinite, value > 0 else { return nil }
        let decimal = MoneyRounding.rounded(MoneyRounding.decimal(fromJSONNumber: value), scale: 2)
        return decimal > 0 ? decimal : nil
    }

    /// What to do with an intent's input. The amount is in the account
    /// currency (an intent has no currency parameter), the date is now,
    /// the note is the description verbatim. A category of the other type
    /// is dropped and the prediction used instead.
    static func plan(_ input: QuickEntryIntentInput, context: QuickEntryContext, now: Date = Date()) -> QuickEntryIntentPlan {
        let note = input.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A named account that is gone: don't silently book elsewhere.
        if let accountId = input.accountId, context.account(accountId) == nil {
            return .openApp(request(for: input))
        }
        let category: QuickEntryOverrides.CategoryChoice = {
            guard let id = input.categoryId, let cat = context.displayCategory(id),
                  cat.type.rawValue == input.type.rawValue else { return .automatic }
            return .category(cat.id)
        }()
        let draft = QuickEntryEngine.draft(
            text: note,
            mode: input.type,
            overrides: QuickEntryOverrides(
                type: input.type,
                amount: input.amount,
                accountId: input.accountId,
                category: category,
                description: note
            ),
            context: context,
            now: now
        )
        guard draft.isReadyToSave else { return .openApp(request(for: input)) }
        return .save(draft)
    }

    static func request(for input: QuickEntryIntentInput, now: Date = Date()) -> QuickEntryRequest {
        QuickEntryRequest(
            mode: input.type == .income ? .income : .expense,
            source: .siri,
            amount: input.amount,
            categoryId: input.categoryId,
            accountId: input.accountId,
            note: input.note,
            createdAt: now
        )
    }

    static func handOverText(_ reason: QuickEntryHost.Unavailable) -> String {
        switch reason {
        case .signedOut: String(localized: "quickEntry.intent.handOver.signIn")
        case .notRunning, .noData: String(localized: "quickEntry.intent.handOver.finish")
        }
    }

    /// «1 234,5 ₽» — the amount as entered, in its own currency.
    static func amountText(_ draft: QuickEntryDraft) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.groupingSeparator = " "
        let number = formatter.string(from: (draft.amount ?? 0) as NSDecimalNumber) ?? "0"
        return "\(number) \(CurrencyCatalog.symbol(for: draft.currencyCode))"
    }

    static func savedText(draft: QuickEntryDraft, context: QuickEntryContext) -> String {
        let amount = amountText(draft)
        let account = context.account(draft.accountId)?.name ?? ""
        let isIncome = draft.type == .income
        if let category = context.displayCategory(draft.categoryId)?.name {
            let format = String(localized: isIncome ? "quickEntry.intent.saved.income.category" : "quickEntry.intent.saved.expense.category")
            return String(format: format, amount, category, account)
        }
        let format = String(localized: isIncome ? "quickEntry.intent.saved.income" : "quickEntry.intent.saved.expense")
        return String(format: format, amount, account)
    }

    static func largeExpenseText(draft: QuickEntryDraft, context: QuickEntryContext) -> String {
        String(format: String(localized: "quickEntry.intent.confirmLarge"), amountText(draft))
    }

    /// Categories whose name matches `query` (Siri «в категорию Кафе»).
    static func categories(matching query: String, in categories: [Category]) -> [Category] {
        let keys = QuickEntryText.matchKeys(query)
        guard !keys.isEmpty else { return categories }
        return categories
            .map { ($0, QuickEntryText.overlap(keys, QuickEntryText.matchKeys($0.name))) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

// MARK: - App Shortcuts (Siri phrases; localized in AppShortcuts.xcstrings)

struct AkifiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "Добавь расход в \(.applicationName)",
                "Записать трату в \(.applicationName)",
                "Запиши трату в \(.applicationName)",
                "Новый расход в \(.applicationName)"
            ],
            shortTitle: "quickEntry.shortcut.expense",
            systemImageName: "minus.circle"
        )
        AppShortcut(
            intent: AddIncomeIntent(),
            phrases: [
                "Добавь доход в \(.applicationName)",
                "Записать доход в \(.applicationName)"
            ],
            shortTitle: "quickEntry.shortcut.income",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: StartVoiceEntryIntent(),
            phrases: [
                "Голосовой ввод в \(.applicationName)",
                "Продиктовать трату в \(.applicationName)"
            ],
            shortTitle: "quickEntry.shortcut.voice",
            systemImageName: "mic"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
