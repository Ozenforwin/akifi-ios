import Foundation
import Observation

/// A request to open the quick-entry sheet — from a link, a Home-screen
/// quick action, the Control Center button or Siri handing over to the app.
struct QuickEntryRequest: Equatable, Sendable, Identifiable {
    enum Source: String, Equatable, Sendable {
        case link, quickAction, control, siri, shortcut
        /// Inside the app: the «+» button and the assistant's «add» actions.
        case addButton, assistant
    }

    let id: UUID
    var mode: QuickEntryLaunchMode
    var source: Source
    /// Phrase to prefill («кофе 300») — goes through the parser.
    var text: String?
    var amount: Decimal?
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

    /// Seed for `QuickEntryEngine.draft(text:mode:overrides:…)`.
    var overrides: QuickEntryOverrides {
        QuickEntryOverrides(
            amount: amount,
            accountId: accountId,
            category: categoryId.map { .category($0) } ?? .automatic,
            description: note
        )
    }
}

/// Parsing and building of `akifi://quick-add` links (see
/// `QuickEntryLaunchURL`).
enum QuickEntryLink {
    /// Longest phrase / note a link may carry.
    static let maxTextLength = 200

    static func url(for request: QuickEntryRequest) -> URL {
        typealias Q = QuickEntryLaunchURL.Query
        var extra: [URLQueryItem] = []
        if let text = request.text, !text.isEmpty { extra.append(URLQueryItem(name: Q.text, value: text)) }
        if let amount = request.amount {
            extra.append(URLQueryItem(name: Q.amount, value: NSDecimalNumber(decimal: amount).description(withLocale: Locale(identifier: "en_US_POSIX"))))
        }
        if let id = request.categoryId { extra.append(URLQueryItem(name: Q.category, value: id)) }
        if let id = request.accountId { extra.append(URLQueryItem(name: Q.account, value: id)) }
        if let note = request.note, !note.isEmpty { extra.append(URLQueryItem(name: Q.note, value: note)) }
        return QuickEntryLaunchURL.make(mode: request.mode, source: request.source.rawValue, extra: extra)
    }

    /// The request in `url`, or nil when it isn't a quick-add link.
    /// Unknown / malformed values are dropped, never guessed.
    static func parse(_ url: URL, now: Date = Date()) -> QuickEntryRequest? {
        guard url.scheme?.lowercased() == QuickEntryLaunchURL.scheme,
              url.host?.lowercased() == QuickEntryLaunchURL.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        typealias Q = QuickEntryLaunchURL.Query
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            if let value = item.value { values[item.name] = value }
        }
        let mode = values[Q.mode].flatMap { QuickEntryLaunchMode(rawValue: $0.lowercased()) } ?? .expense
        let source = values[Q.source].flatMap { QuickEntryRequest.Source(rawValue: $0) } ?? .link
        let amount = values[Q.amount]
            .flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            .flatMap { $0 > 0 && $0 < 1_000_000_000_000 ? $0 : nil }
        return QuickEntryRequest(
            mode: mode,
            source: source,
            text: cleaned(values[Q.text]),
            amount: amount,
            categoryId: identifier(values[Q.category]),
            accountId: identifier(values[Q.account]),
            note: cleaned(values[Q.note]),
            createdAt: now
        )
    }

    private static func cleaned(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTextLength))
    }

    /// Row ids are UUIDs; anything else is ignored.
    private static func identifier(_ s: String?) -> String? {
        guard let s, let uuid = UUID(uuidString: s) else { return nil }
        return uuid.uuidString.lowercased()
    }

    // MARK: - Home-screen quick actions

    static let shortcutTypePrefix = "ru.akifi.app.quickEntry."

    static func shortcutType(for mode: QuickEntryLaunchMode) -> String {
        shortcutTypePrefix + mode.rawValue
    }

    static func request(forShortcutType type: String, now: Date = Date()) -> QuickEntryRequest? {
        guard type.hasPrefix(shortcutTypePrefix),
              let mode = QuickEntryLaunchMode(rawValue: String(type.dropFirst(shortcutTypePrefix.count))) else { return nil }
        return QuickEntryRequest(mode: mode, source: .quickAction, createdAt: now)
    }
}

/// Where quick-entry requests wait for the signed-in UI.
///
/// Producers: `AppViewModel.open(_:)` (links), the quick-action scene
/// delegate, Siri / Shortcuts handing over to the app.
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
