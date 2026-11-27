import AppIntents
import Foundation

// The «Счёт» widget's configuration. Compiled into the widget extension
// (where WidgetKit runs the query when the user edits the widget) and the
// app (tests); it reads only the App Group snapshot, never the network.

/// Which account a «Счёт» widget shows, without the network: the
/// snapshot's money accounts. Pure, so the query and the timeline agree.
enum AccountWidgetSelection {
    /// The accounts to pick from, in the app's order. Empty without a v2
    /// snapshot (signed out, fresh install, a 1.5.x file).
    static func choices(in snapshot: SharedSnapshot?) -> [SharedSnapshot.AccountItem] {
        snapshot?.accounts ?? []
    }

    /// A new widget shows the primary account (else the first).
    static func defaultAccount(in snapshot: SharedSnapshot?) -> SharedSnapshot.AccountItem? {
        let accounts = choices(in: snapshot)
        return accounts.first(where: \.isPrimary) ?? accounts.first
    }

    /// The configured account while it exists; a deleted, unknown or
    /// someone else's id (or none) falls back to the default — never to
    /// nothing while the user has accounts.
    static func resolve(id: String?, in snapshot: SharedSnapshot?) -> SharedSnapshot.AccountItem? {
        if let id, let match = choices(in: snapshot).first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return match
        }
        return defaultAccount(in: snapshot)
    }
}

/// An account in the widget's «Счёт» picker.
struct AccountWidgetEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.account.entity")
    static let defaultQuery = AccountWidgetEntityQuery()

    let id: String
    let name: String
    let icon: String
    let currencyCode: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(icon) \(name)", subtitle: "\(currencyCode)")
    }

    init(id: String, name: String, icon: String, currencyCode: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.currencyCode = currencyCode
    }

    init(_ item: SharedSnapshot.AccountItem) {
        self.init(id: item.id, name: item.name, icon: item.icon, currencyCode: item.currencyCode)
    }
}

/// The picker's data: the snapshot's money accounts. The instance methods
/// are what WidgetKit calls; the static ones are the same answers for a
/// given snapshot (tested).
struct AccountWidgetEntityQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [AccountWidgetEntity] {
        Self.entities(for: identifiers, in: SharedSnapshotStore.load())
    }

    func suggestedEntities() async throws -> [AccountWidgetEntity] {
        Self.suggested(in: SharedSnapshotStore.load())
    }

    func defaultResult() async -> AccountWidgetEntity? {
        Self.defaultEntity(in: SharedSnapshotStore.load())
    }

    /// Only accounts that still exist: a stale id resolves to nothing here
    /// (the timeline then shows the default account).
    static func entities(for identifiers: [String], in snapshot: SharedSnapshot?) -> [AccountWidgetEntity] {
        let accounts = AccountWidgetSelection.choices(in: snapshot)
        return identifiers.compactMap { id in
            accounts.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }.map(AccountWidgetEntity.init)
        }
    }

    static func suggested(in snapshot: SharedSnapshot?) -> [AccountWidgetEntity] {
        AccountWidgetSelection.choices(in: snapshot).map(AccountWidgetEntity.init)
    }

    static func defaultEntity(in snapshot: SharedSnapshot?) -> AccountWidgetEntity? {
        AccountWidgetSelection.defaultAccount(in: snapshot).map(AccountWidgetEntity.init)
    }
}

/// «Счёт» widget configuration: one parameter, the account.
struct AccountWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.account.intent.title"
    static let description = IntentDescription("widget.account.intent.description")
    /// A widget setting, not a Shortcuts action.
    static let isDiscoverable = false

    @Parameter(title: "widget.account.intent.account")
    var account: AccountWidgetEntity?

    init() {}

    init(account: AccountWidgetEntity?) {
        self.account = account
    }
}
