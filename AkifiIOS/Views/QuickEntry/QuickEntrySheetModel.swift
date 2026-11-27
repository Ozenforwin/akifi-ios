import Foundation
import Observation

/// One category chip of the quick-entry sheet.
struct QuickEntryCategoryChip: Equatable, Identifiable {
    let category: Category
    let isSelected: Bool
    /// Ranked by the predictor (the rest of the row is filled with the
    /// type's categories in picker order).
    let isSuggested: Bool

    var id: String { category.id }
}

/// What the live line under the field says: «Кофе · 300 ₽ · сегодня ·
/// Тинькофф».
struct QuickEntrySummary: Equatable {
    /// Description, else the category's name; nil when neither.
    var title: String?
    /// «300 ₽» in the entry currency; nil until there is an amount.
    var amount: String?
    var date: String
    var account: String?

    var segments: [String] {
        [title, amount, date, account].compactMap { $0 }
    }
}

/// Voice state of the sheet, as the UI shows it.
enum QuickEntryVoiceStatus: Equatable {
    case requestingPermission
    case listening
    case deniedMicrophone
    case deniedSpeech
    case restricted
    case unavailable
    case failed

    /// The status offers a button to the app's page in Settings.
    var offersSettings: Bool {
        self == .deniedMicrophone || self == .deniedSpeech
    }

    /// Voice can't be used now: the sheet falls back to the keyboard.
    var fallsBackToTyping: Bool {
        switch self {
        case .deniedMicrophone, .deniedSpeech, .restricted, .unavailable, .failed: true
        case .requestingPermission, .listening: false
        }
    }

    init?(_ state: SpeechQuickEntry.State) {
        switch state {
        case .idle, .finished: return nil
        case .requestingPermission: self = .requestingPermission
        case .listening, .finishing: self = .listening
        case .denied(.microphone): self = .deniedMicrophone
        case .denied(.speech): self = .deniedSpeech
        case .denied(.restricted): self = .restricted
        case .unavailable: self = .unavailable
        case .failed: self = .failed
        }
    }
}

/// A saved quick entry — what the «Записано: … · Отменить» toast shows and
/// undoes.
struct QuickEntrySaved: Identifiable, Equatable {
    enum Method: String, Equatable, Sendable {
        case text, voice, `repeat`
    }

    let id: UUID
    /// The stored (or offline-queued) row.
    let transaction: Transaction
    /// «Кофе 300 ₽».
    let label: String
    let method: Method

    init(id: UUID = UUID(), transaction: Transaction, label: String, method: Method) {
        self.id = id
        self.transaction = transaction
        self.label = label
        self.method = method
    }

    /// «Записано: Кофе 300 ₽».
    var toastText: String {
        String(format: String(localized: "quickEntry.toast.saved"), label)
    }

    static func == (lhs: QuickEntrySaved, rhs: QuickEntrySaved) -> Bool {
        lhs.id == rhs.id && lhs.transaction.id == rhs.transaction.id && lhs.label == rhs.label && lhs.method == rhs.method
    }
}

/// State of the quick-entry sheet (1.6.0 «быстрый ввод»).
///
/// The draft is never edited in place: every keystroke, chip tap or voice
/// update changes the phrase or the `QuickEntryOverrides`, and the draft is
/// recomputed by `QuickEntryEngine` (parsing, defaults and prediction live
/// there). Saving goes through `QuickEntrySubmitter` — the one quick-entry
/// write path (ADR-001 amounts, offline queue, live session).
///
/// Prefilled values (a «Повторить» item, a Siri / link hand-over) are
/// overrides shown as a phrase in the field. As soon as the user edits that
/// phrase it takes over again: the prefilled amount, currency and
/// description are dropped (type, account and category stay — they are
/// visible chips).
@Observable @MainActor
final class QuickEntrySheetModel {

    enum SaveOutcome: Equatable {
        case saved(QuickEntrySaved)
        /// The form's large-expense guard fired — ask, then call
        /// `save(confirmingLargeExpense: true)`.
        case needsLargeExpenseConfirmation(TransactionGuards.LargeExpenseDecision)
        /// Not ready (no amount / account) or already saving.
        case notReady
        case failed(String)
    }

    /// Category chips in the row (the «Все» chip comes after them).
    static let chipCount = 6
    static let repeatLimit = 6

    // MARK: - State

    private(set) var context: QuickEntryContext
    let source: QuickEntryRequest.Source
    let startsWithVoice: Bool
    let speech: SpeechQuickEntry

    /// The field: amount and words («кофе 300 вчера»).
    var text: String {
        didSet {
            guard text != oldValue else { return }
            textDidChange()
        }
    }

    private(set) var overrides: QuickEntryOverrides
    private(set) var draft: QuickEntryDraft
    /// The «Повторить» item the draft came from, until the phrase is edited.
    private(set) var appliedRepeatId: String?
    private(set) var isSaving = false
    var errorMessage: String?

    /// The mode the sheet was opened in (expense / income).
    @ObservationIgnored private let mode: TransactionType
    @ObservationIgnored private let now: () -> Date
    /// Prefilled amount / currency / description are live (see the type doc).
    @ObservationIgnored private var hasPrefilledOverrides = false
    @ObservationIgnored private var isSettingTextProgrammatically = false
    @ObservationIgnored private var repeatCache: [TransactionType: [QuickEntryRepeatItem]] = [:]
    /// Field text when the current dictation started; nil when not dictating.
    @ObservationIgnored private var textBeforeVoice: String?
    @ObservationIgnored private var usedVoice = false
    /// The currency chip was used: the amount stays in that currency while
    /// the phrase is edited.
    @ObservationIgnored private var currencyChosenByUser = false

    /// Write seam — production: `QuickEntrySubmitter.submit`.
    @ObservationIgnored var submit: @MainActor (QuickEntryDraft) async throws -> Transaction
    /// Large-expense seam — production: `QuickEntrySubmitter.largeExpenseDecision`.
    @ObservationIgnored var largeExpenseDecision: @MainActor (QuickEntryDraft) -> TransactionGuards.LargeExpenseDecision?

    init(
        context: QuickEntryContext,
        request: QuickEntryRequest,
        submitter: QuickEntrySubmitter,
        speech: SpeechQuickEntry,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.source = request.source
        self.startsWithVoice = request.startsWithVoice
        self.speech = speech
        self.mode = request.transactionType
        self.now = now
        self.submit = { draft in try await submitter.submit(draft) }
        self.largeExpenseDecision = { draft in submitter.largeExpenseDecision(for: draft) }

        let seed = Self.seed(for: request)
        self.text = seed.text
        self.overrides = seed.overrides
        self.hasPrefilledOverrides = seed.hasPrefilledOverrides
        self.draft = QuickEntryEngine.draft(text: seed.text, mode: request.transactionType, overrides: seed.overrides, context: context, now: now())
    }

    // MARK: - Derived

    var canSave: Bool { draft.isReadyToSave && !isSaving }

    var account: Account? { context.account(draft.accountId) }

    /// The amount's currency (the chip), nil for a code outside the catalog.
    var entryCurrency: Currency? { Currency(code: draft.currencyCode.uppercased()) }

    var accounts: [Account] { context.accounts }

    var selectedCategory: Category? { context.displayCategory(draft.categoryId) }

    /// The type's display categories (the full picker behind «Все»).
    var categoriesForType: [Category] { context.displayCategories(for: draft.type) }

    /// Up to `chipCount` chips: the predictor's ranking, then the type's
    /// categories in picker order. A category picked outside the row (the
    /// «Все» picker) leads it.
    var categoryChips: [QuickEntryCategoryChip] {
        let all = context.displayCategories(for: draft.type)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let suggested = draft.suggestions.map(\.categoryId).filter { byId[$0] != nil }
        var ids: [String] = []
        for id in suggested + all.map(\.id) where !ids.contains(id) {
            ids.append(id)
        }
        var row = Array(ids.prefix(Self.chipCount))
        if let selected = draft.categoryId, byId[selected] != nil, !row.contains(selected) {
            row.insert(selected, at: 0)
            row = Array(row.prefix(Self.chipCount))
        }
        let suggestedSet = Set(suggested)
        return row.compactMap { id in
            byId[id].map {
                QuickEntryCategoryChip(category: $0, isSelected: draft.categoryId == id, isSuggested: suggestedSet.contains(id))
            }
        }
    }

    /// Recent entries of the current type to repeat with one tap.
    var repeatCandidates: [QuickEntryRepeatItem] {
        let type = draft.type
        if let cached = repeatCache[type] { return cached }
        let items = QuickEntryPredictor.repeatCandidates(context: context, type: type, limit: Self.repeatLimit)
        repeatCache[type] = items
        return items
    }

    /// The strip shows on an untouched field (and while a repeat is applied).
    var showsRepeatStrip: Bool {
        guard !repeatCandidates.isEmpty else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appliedRepeatId != nil
    }

    var summary: QuickEntrySummary {
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickEntrySummary(
            title: description.isEmpty ? selectedCategory?.name : description,
            amount: draft.amount.map { _ in QuickEntryIntentSupport.amountText(draft) },
            date: Self.dayLabel(draft.date, now: now(), calendar: context.calendar, capitalized: false),
            account: account?.name
        )
    }

    /// Nothing typed yet — the line shows a hint instead of the summary.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.amount == nil
    }

    var dateChipLabel: String {
        Self.dayLabel(draft.date, now: now(), calendar: context.calendar, capitalized: true)
    }

    var voiceStatus: QuickEntryVoiceStatus? { QuickEntryVoiceStatus(speech.state) }

    /// «Подробнее»: the full form with what the sheet has.
    var formPrefill: TransactionFormPrefill {
        let accountCurrency = account?.currency.uppercased() ?? context.fallbackCurrency
        let entryCurrency = draft.currencyCode.uppercased()
        return TransactionFormPrefill(
            type: draft.type == .income ? .income : .expense,
            amount: draft.amount,
            currencyCode: entryCurrency == accountCurrency ? nil : entryCurrency,
            accountId: draft.accountId,
            categoryId: draft.categoryId,
            date: draft.date,
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Edits

    /// The Расход / Доход control.
    func setType(_ type: TransactionType) {
        guard type == .expense || type == .income else { return }
        let changed = type != draft.type
        overrides.type = type
        // A category of the other type never carries over — let the
        // prediction for the new type pick again.
        if changed, case .category = overrides.category {
            overrides.category = .automatic
        }
        recompute()
    }

    /// A tap on a category chip. Returns true when the draft is complete —
    /// the sheet then saves right away (amount → category = done).
    @discardableResult
    func chooseCategory(_ id: String) -> Bool {
        overrides.category = .category(id)
        recompute()
        return draft.isReadyToSave
    }

    /// The «Все» picker's «Без категории».
    func clearCategory() {
        overrides.category = .none
        recompute()
    }

    func chooseAccount(_ id: String) {
        guard context.account(id) != nil else { return }
        overrides.accountId = id
        recompute()
    }

    /// `offset` days from today (0 today, -1 yesterday), at the current
    /// time of day — like the parser's «вчера».
    func chooseDay(offset: Int) {
        let today = now()
        let day = context.calendar.date(byAdding: .day, value: offset, to: today) ?? today
        chooseDate(day)
    }

    func chooseDate(_ date: Date) {
        overrides.date = date
        recompute()
    }

    /// The currency chip: the amount is in `code` — over a «$» / «€» in the
    /// phrase, and kept while the phrase is edited. Equal to the account's
    /// currency = no conversion; another one is converted on save (ADR-001).
    func chooseCurrency(_ code: String) {
        overrides.currencyCode = code.uppercased()
        currencyChosenByUser = true
        recompute()
    }

    /// One tap on a «Повторить» item: its description, amount, category and
    /// account, today.
    func applyRepeat(_ item: QuickEntryRepeatItem) {
        var o = item.overrides
        // In the account's own currency the amount follows the account if
        // the user switches it (like the form); a foreign entry keeps its
        // currency and is converted again on save.
        if item.currencyCode.uppercased() == item.accountCurrency.uppercased() {
            o.currencyCode = nil
        }
        overrides = o
        hasPrefilledOverrides = true
        currencyChosenByUser = false
        appliedRepeatId = item.id
        setTextProgrammatically(Self.phrase(description: item.description, amount: item.amount, currency: item.currencyCode == item.accountCurrency ? nil : item.currencyCode))
        recompute()
    }

    /// The data store changed under the open sheet (first load finished,
    /// another device synced): same phrase and choices, fresh snapshot.
    func updateContext(_ context: QuickEntryContext) {
        self.context = context
        repeatCache = [:]
        recompute()
    }

    // MARK: - Voice

    /// Starts a dictation; the transcript goes into the field after what is
    /// already there.
    func startVoice() async {
        guard !speech.isListening, speech.state != .requestingPermission else { return }
        textBeforeVoice = text.trimmingCharacters(in: .whitespacesAndNewlines)
        usedVoice = true
        speech.onFinish = { [weak self] text in
            self?.finishVoice(text)
        }
        await speech.start(contextualStrings: QuickEntryEngine.contextualStrings(context: context))
        speechStateDidChange()
    }

    func stopVoice() {
        speech.stop()
    }

    func cancelVoice() {
        speech.cancel()
        textBeforeVoice = nil
    }

    /// A partial transcript arrived.
    func applyTranscript(_ transcript: String) {
        guard let prefix = textBeforeVoice else { return }
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        text = [prefix, heard].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The final transcript.
    func finishVoice(_ transcript: String) {
        applyTranscript(transcript)
        textBeforeVoice = nil
    }

    /// Call when `speech.state` changes: a dictation that ended without
    /// words (or never started) stops feeding the field.
    func speechStateDidChange() {
        switch speech.state {
        case .listening, .finishing, .requestingPermission:
            break
        case .idle, .finished, .denied, .unavailable, .failed:
            textBeforeVoice = nil
        }
    }

    // MARK: - Save

    func save(confirmingLargeExpense: Bool = false) async -> SaveOutcome {
        let draft = self.draft
        guard draft.isReadyToSave, !isSaving else { return .notReady }
        if !confirmingLargeExpense, let decision = largeExpenseDecision(draft), decision.shouldConfirm {
            return .needsLargeExpenseConfirmation(decision)
        }
        if speech.isListening { speech.cancel() }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let transaction = try await submit(draft)
            let method: QuickEntrySaved.Method = appliedRepeatId != nil ? .repeat : (usedVoice ? .voice : .text)
            AnalyticsService.logEvent("quick_entry_saved", params: ["method": method.rawValue, "target": source.rawValue])
            return .saved(QuickEntrySaved(transaction: transaction, label: Self.label(for: draft, context: context), method: method))
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            return .failed(message)
        }
    }

    // MARK: - Internals

    private func textDidChange() {
        if !isSettingTextProgrammatically, hasPrefilledOverrides {
            // The user edits the phrase: it says the amount and the words now.
            hasPrefilledOverrides = false
            appliedRepeatId = nil
            overrides.amount = nil
            if !currencyChosenByUser { overrides.currencyCode = nil }
            overrides.description = nil
        }
        recompute()
    }

    private func setTextProgrammatically(_ value: String) {
        isSettingTextProgrammatically = true
        text = value
        isSettingTextProgrammatically = false
    }

    private func recompute() {
        draft = QuickEntryEngine.draft(text: text, mode: mode, overrides: overrides, context: context, now: now())
    }

    // MARK: - Pure helpers (tested)

    struct Seed: Equatable {
        var text: String
        var overrides: QuickEntryOverrides
        var hasPrefilledOverrides: Bool
    }

    /// Field text and overrides for a request. A plain phrase is just
    /// typed in; an amount / note (Siri hand-over, a link) become prefilled
    /// overrides shown as a phrase («кофе 300»).
    static func seed(for request: QuickEntryRequest) -> Seed {
        var overrides = request.overrides
        let phrase = request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefilled = request.amount != nil || request.note != nil
        guard prefilled else {
            overrides.description = nil
            return Seed(text: phrase, overrides: overrides, hasPrefilledOverrides: false)
        }
        let base = phrase.isEmpty ? (request.note ?? "") : phrase
        let text: String
        if let amount = request.amount, QuickEntryParser.parse(base).amount == nil {
            // A foreign currency (a widget's «Повторить» item) is said in
            // the phrase, like the in-sheet repeat does.
            text = Self.phrase(description: base, amount: amount, currency: request.currencyCode)
        } else {
            text = base
        }
        return Seed(text: text, overrides: overrides, hasPrefilledOverrides: true)
    }

    /// «Кофе 300», «Netflix 12.99 USD» — what a prefilled draft shows in the
    /// field; parsing it gives the same amount and words back.
    static func phrase(description: String, amount: Decimal, currency: String?) -> String {
        let number = NSDecimalNumber(decimal: amount).description(withLocale: Locale(identifier: "en_US_POSIX"))
        return [description.trimmingCharacters(in: .whitespacesAndNewlines), number, currency?.uppercased() ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// «Кофе 300 ₽» — the description (else the category, else the type) and
    /// the amount as entered.
    static func label(for draft: QuickEntryDraft, context: QuickEntryContext) -> String {
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = {
            if !description.isEmpty { return description }
            if let category = context.displayCategory(draft.categoryId) { return category.name }
            return draft.type == .income ? String(localized: "common.income") : String(localized: "common.expense")
        }()
        return "\(title) \(QuickEntryIntentSupport.amountText(draft))"
    }

    /// «Сегодня» / «Вчера» / «12 нояб.» (lowercased inside the summary line).
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar, capitalized: Bool) -> String {
        let label: String
        if calendar.isDate(date, inSameDayAs: now) {
            label = String(localized: "date.today")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            label = String(localized: "date.yesterday")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return AppDateFormatters.dayMonth.string(from: date)
        } else {
            return AppDateFormatters.dayMonthYear.string(from: date)
        }
        return capitalized ? label : label.lowercased()
    }
}
