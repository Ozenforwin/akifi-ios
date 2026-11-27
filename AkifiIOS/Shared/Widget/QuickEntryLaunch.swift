import AppIntents
import Foundation

// Compiled into the app AND the widget extension (project.yml): the
// Control Center button and the home / Lock Screen widgets live in the
// extension, while the intent must also exist in the app so the system can
// run it there and open the app.

/// How the quick-entry sheet opens.
enum QuickEntryLaunchMode: String, AppEnum, Sendable, CaseIterable {
    case expense
    case income
    case voice

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "quickEntry.mode.type")
    static let caseDisplayRepresentations: [QuickEntryLaunchMode: DisplayRepresentation] = [
        .expense: DisplayRepresentation(title: "quickEntry.mode.expense", image: .init(systemName: "minus.circle")),
        .income: DisplayRepresentation(title: "quickEntry.mode.income", image: .init(systemName: "plus.circle")),
        .voice: DisplayRepresentation(title: "quickEntry.mode.voice", image: .init(systemName: "mic"))
    ]
}

/// Who asked for quick entry — analytics' `target` and the log line.
enum QuickEntryLaunchSource: String, Equatable, Sendable, CaseIterable {
    case link, quickAction, control, siri, shortcut
    /// A home-screen or Lock Screen widget («Счёт», «Быстрая запись»).
    case widget
    /// Inside the app: the «+» button and the assistant's «add» actions.
    case addButton, assistant
}

/// `akifi://quick-add` constants.
enum QuickEntryLaunchURL {
    static let scheme = "akifi"
    static let host = "quick-add"

    enum Query {
        static let mode = "mode"
        static let source = "source"
        static let text = "text"
        static let amount = "amount"
        static let currency = "currency"
        static let category = "category"
        static let account = "account"
        static let note = "note"
    }
}

/// One `akifi://quick-add?mode=…&source=…[&text=&amount=&currency=&category=&account=&note=]`
/// link — the ONE builder (`url`) and parser (`init?(url:)`) behind every
/// producer: the widgets, Control Center, the Home-screen quick actions,
/// Siri / Shortcuts links and the app's own hand-overs.
///
/// The link only OPENS the quick-entry sheet, prefilled — it never saves.
/// A link from anywhere can at most show a draft the user still confirms.
/// What the parser can't trust it drops, never guesses: ids must be UUIDs
/// (an unknown or someone else's id is then ignored by the engine — it only
/// knows the user's money accounts), amounts must be positive and sane,
/// texts are trimmed, stripped of control characters and capped.
struct QuickEntryLaunchLink: Equatable, Sendable {
    /// Longest phrase / note a link may carry.
    static let maxTextLength = 200
    /// Amounts at or above this are not a typo we want to prefill.
    static let maxAmount: Decimal = 1_000_000_000_000

    var mode: QuickEntryLaunchMode
    var source: QuickEntryLaunchSource
    /// Phrase to prefill («кофе 300») — goes through the parser.
    var text: String?
    /// Main units (not kopecks).
    var amount: Decimal?
    /// ISO code of `amount` when it is not the account's currency.
    var currency: String?
    var categoryId: String?
    var accountId: String?
    /// Description to prefill as is.
    var note: String?

    init(
        mode: QuickEntryLaunchMode,
        source: QuickEntryLaunchSource,
        text: String? = nil,
        amount: Decimal? = nil,
        currency: String? = nil,
        categoryId: String? = nil,
        accountId: String? = nil,
        note: String? = nil
    ) {
        self.mode = mode
        self.source = source
        self.text = text
        self.amount = amount
        self.currency = currency
        self.categoryId = categoryId
        self.accountId = accountId
        self.note = note
    }

    // MARK: - Build

    var url: URL {
        typealias Q = QuickEntryLaunchURL.Query
        var items = [
            URLQueryItem(name: Q.mode, value: mode.rawValue),
            URLQueryItem(name: Q.source, value: source.rawValue)
        ]
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }
        add(Q.text, text)
        add(Q.amount, amount.map { NSDecimalNumber(decimal: $0).description(withLocale: Self.posix) })
        add(Q.currency, currency?.uppercased())
        add(Q.category, categoryId)
        add(Q.account, accountId)
        add(Q.note, note)

        var components = URLComponents()
        components.scheme = QuickEntryLaunchURL.scheme
        components.host = QuickEntryLaunchURL.host
        components.queryItems = items
        // `+` is legal in a query but many decoders read it as a space;
        // «+5000» must survive the trip.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        // Built from constants and encoded values — always valid.
        return components.url ?? URL(string: "\(QuickEntryLaunchURL.scheme)://\(QuickEntryLaunchURL.host)")!
    }

    // MARK: - Parse

    /// The link in `url`, or nil when it isn't a quick-add link.
    init?(url: URL) {
        guard url.scheme?.lowercased() == QuickEntryLaunchURL.scheme,
              url.host?.lowercased() == QuickEntryLaunchURL.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        typealias Q = QuickEntryLaunchURL.Query
        var values: [String: String] = [:]
        // The first occurrence wins: an appended duplicate can't override.
        for item in components.queryItems ?? [] where values[item.name] == nil {
            if let value = item.value { values[item.name] = value }
        }
        self.init(
            mode: values[Q.mode].flatMap { QuickEntryLaunchMode(rawValue: $0.lowercased()) } ?? .expense,
            source: values[Q.source].flatMap { QuickEntryLaunchSource(rawValue: $0) } ?? .link,
            text: Self.cleaned(values[Q.text]),
            amount: values[Q.amount]
                .flatMap { Decimal(string: $0, locale: Self.posix) }
                .flatMap { $0 > 0 && $0 < Self.maxAmount ? $0 : nil },
            currency: Self.currencyCode(values[Q.currency]),
            categoryId: Self.identifier(values[Q.category]),
            accountId: Self.identifier(values[Q.account]),
            note: Self.cleaned(values[Q.note])
        )
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func cleaned(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTextLength))
    }

    /// Row ids are UUIDs (lowercased like the database); anything else is
    /// ignored.
    private static func identifier(_ s: String?) -> String? {
        guard let s, let uuid = UUID(uuidString: s) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// Three ASCII letters, uppercased. Whether the code is a currency the
    /// app knows is the app's call (`QuickEntryLink.parse`).
    private static func currencyCode(_ s: String?) -> String? {
        guard let s, s.count == 3, s.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) })
        else { return nil }
        return s.uppercased()
    }
}

/// Opens Akifi straight into quick entry. Used by the Control Center
/// button and the «Голосом» App Shortcut.
struct OpenQuickEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "quickEntry.intent.open.title"
    static let description = IntentDescription("quickEntry.intent.open.description")
    static let openAppWhenRun = true
    /// Shortcuts gets the dedicated add / voice intents instead.
    static let isDiscoverable = false

    @Parameter(title: "quickEntry.intent.open.mode", default: .expense)
    var mode: QuickEntryLaunchMode

    init() {}

    init(mode: QuickEntryLaunchMode) {
        self.mode = mode
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(QuickEntryLaunchLink(mode: mode, source: .control).url))
    }
}
