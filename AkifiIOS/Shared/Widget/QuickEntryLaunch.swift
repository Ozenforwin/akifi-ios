import AppIntents
import Foundation

// Compiled into the app AND the widget extension (project.yml): the
// Control Center button lives in the extension, while the intent must also
// exist in the app so the system can run it there and open the app.

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

/// `akifi://quick-add?mode=expense&source=control[&text=…&amount=…]`
///
/// The URL only OPENS the quick-entry sheet, prefilled — it never saves.
/// A link from anywhere can at most show a draft the user still confirms.
enum QuickEntryLaunchURL {
    static let scheme = "akifi"
    static let host = "quick-add"

    enum Query {
        static let mode = "mode"
        static let source = "source"
        static let text = "text"
        static let amount = "amount"
        static let category = "category"
        static let account = "account"
        static let note = "note"
    }

    static func make(mode: QuickEntryLaunchMode, source: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: Query.mode, value: mode.rawValue),
            URLQueryItem(name: Query.source, value: source)
        ] + extra
        // Built from constants — always valid.
        return components.url ?? URL(string: "\(scheme)://\(host)")!
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
        .result(opensIntent: OpenURLIntent(QuickEntryLaunchURL.make(mode: mode, source: "control")))
    }
}
