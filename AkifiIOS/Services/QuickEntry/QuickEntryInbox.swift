import Foundation
import Observation

/// A request to open the quick-entry sheet — from a link, a widget, a
/// Home-screen quick action, the Control Center button or Siri handing over
/// to the app.
struct QuickEntryRequest: Equatable, Sendable, Identifiable {
    typealias Source = QuickEntryLaunchSource

    let id: UUID
    var mode: QuickEntryLaunchMode
    var source: Source
    /// Phrase to prefill («кофе 300») — goes through the parser.
    var text: String?
    var amount: Decimal?
    /// Currency of `amount` when it isn't the account's (ISO, uppercase).
    var currencyCode: String?
    var categoryId: String?
    var accountId: String?
    var note: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        mode: QuickEntryLaunchMode,
        source: Source,
        text: String? = nil,
        amount: Decimal? = nil,
        currencyCode: String? = nil,
        categoryId: String? = nil,
        accountId: String? = nil,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.source = source
        self.text = text
        self.amount = amount
        self.currencyCode = currencyCode
        self.categoryId = categoryId
        self.accountId = accountId
        self.note = note
        self.createdAt = createdAt
    }

    /// Expense unless the request is for income (voice starts as expense;
    /// the phrase can still say «+» / «зарплата»).
    var transactionType: TransactionType {
        mode == .income ? .income : .expense
    }

    var startsWithVoice: Bool { mode == .voice }

    /// Seed for `QuickEntryEngine.draft(text:mode:overrides:…)`. The
    /// account is a preselection the engine honours only when it is one of
    /// the user's money accounts — an unknown, deleted, debt or someone
    /// else's id falls back to the usual default account.
    var overrides: QuickEntryOverrides {
        QuickEntryOverrides(
            amount: amount,
            currencyCode: currencyCode,
            accountId: accountId,
            category: categoryId.map { .category($0) } ?? .automatic,
            description: note
        )
    }

    /// The link that opens this request (the shared builder).
    var link: QuickEntryLaunchLink {
        QuickEntryLaunchLink(
            mode: mode, source: source, text: text, amount: amount, currency: currencyCode,
            categoryId: categoryId, accountId: accountId, note: note
        )
    }
}

/// `akifi://quick-add` links on the app side: the shared
/// `QuickEntryLaunchLink` builder / parser, plus what only the app can
/// check (a currency code the catalog knows) and the quick-action types.
enum QuickEntryLink {
    /// Longest phrase / note a link may carry.
    static let maxTextLength = QuickEntryLaunchLink.maxTextLength

    static func url(for request: QuickEntryRequest) -> URL {
        request.link.url
    }

    /// The request in `url`, or nil when it isn't a quick-add link.
    /// Unknown / malformed values are dropped, never guessed.
    static func parse(_ url: URL, now: Date = Date()) -> QuickEntryRequest? {
        guard let link = QuickEntryLaunchLink(url: url) else { return nil }
        return QuickEntryRequest(
            mode: link.mode,
            source: link.source,
            text: link.text,
            amount: link.amount,
            currencyCode: link.currency.flatMap { Currency(code: $0)?.code },
            categoryId: link.categoryId,
            accountId: link.accountId,
            note: link.note,
            createdAt: now
        )
    }

    // MARK: - Home-screen quick actions

    static let shortcutTypePrefix = "ru.akifi.app.quickEntry."

    static func shortcutType(for mode: QuickEntryLaunchMode) -> String {
        shortcutTypePrefix + mode.rawValue
    }

    /// The link a quick action stands for — the same builder the widgets
    /// and Control Center use.
    static func link(forShortcutType type: String) -> QuickEntryLaunchLink? {
        guard type.hasPrefix(shortcutTypePrefix),
              let mode = QuickEntryLaunchMode(rawValue: String(type.dropFirst(shortcutTypePrefix.count))) else { return nil }
        return QuickEntryLaunchLink(mode: mode, source: .quickAction)
    }

    static func request(forShortcutType type: String, now: Date = Date()) -> QuickEntryRequest? {
        link(forShortcutType: type).flatMap { parse($0.url, now: now) }
    }
}

/// Where quick-entry requests wait for the signed-in UI.
///
/// Producers: `AppViewModel.open(_:)` (links — also every widget tap and
/// the Control Center button), the quick-action scene delegate, Siri /
/// Shortcuts handing over to the app. A cold start from a widget lands here
/// too: the URL arrives before the signed-in UI exists and waits.
/// Consumer (the 1.6.0 UI stream): `MainTabView` observes `pending` and
/// presents the quick-entry sheet:
///
/// ```swift
/// .onChange(of: QuickEntryInbox.shared.pending?.id, initial: true) { _, _ in
///     guard let request = QuickEntryInbox.shared.consume() else { return }
///     quickEntryRequest = request          // .sheet(item:)
/// }
/// ```
@Observable @MainActor
final class QuickEntryInbox {
    static let shared = QuickEntryInbox()

    /// A request older than this is dropped instead of popping a sheet
    /// long after the tap (e.g. it waited through a sign-in).
    static let maxAge: TimeInterval = 10 * 60

    private(set) var pending: QuickEntryRequest?

    init() {}

    func submit(_ request: QuickEntryRequest) {
        // Mode and source only — never the phrase or the amount.
        AppLogger.data.info("Quick entry requested: \(request.mode.rawValue, privacy: .public) via \(request.source.rawValue, privacy: .public)")
        pending = request
    }

    /// Takes a quick-add link. Returns false for any other URL so the
    /// caller routes it on.
    @discardableResult
    func open(_ url: URL, now: Date = Date()) -> Bool {
        guard let request = QuickEntryLink.parse(url, now: now) else { return false }
        submit(request)
        return true
    }

    /// Takes a Home-screen quick action. False when it isn't ours.
    @discardableResult
    func handleShortcutItem(type: String, now: Date = Date()) -> Bool {
        guard let request = QuickEntryLink.request(forShortcutType: type, now: now) else { return false }
        submit(request)
        return true
    }

    /// The waiting request, removed from the inbox; nil when none or stale.
    func consume(now: Date = Date()) -> QuickEntryRequest? {
        guard let request = pending else { return nil }
        pending = nil
        guard now.timeIntervalSince(request.createdAt) <= Self.maxAge else { return nil }
        return request
    }

    /// Sign-out: nothing of the previous user may open later.
    func reset() {
        pending = nil
    }
}
