import AppIntents
import Foundation
import WidgetKit

// «Счёт» arrows (1.6.0): ‹ › switch the account a «Счёт» widget shows,
// right on the Home Screen, without opening the app. Compiled into the
// widget extension (the intent runs there, the provider reads its result)
// and the app (tests). No network, no session: the App Group snapshot and
// the App Group defaults only.

/// One remembered arrow step: the account a widget shows now and which
/// way the user went (for the push transition).
struct AccountWidgetOverride: Codable, Equatable, Sendable {
    let accountId: String
    /// true = «›» (next), false = «‹» (previous).
    let forward: Bool
}

/// What the arrows of one «Счёт» widget need to render: where it is in
/// the account list, the neighbours' names for VoiceOver and the intent's
/// parameters.
struct AccountWidgetPager: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        let id: String
        let colorHex: String
    }

    /// `AccountWidgetCarousel.widgetKey(…)` of this widget.
    let widgetKey: String
    /// The account picked in the widget's settings (nil = none picked).
    let configuredAccountId: String?
    /// Every money account in the snapshot's order (= the Home carousel).
    let pages: [Page]
    /// Index of the shown account in `pages`.
    let position: Int
    /// The shown account's name (VoiceOver: «Тинькофф, 2 из 4»).
    let currentName: String
    let previousName: String
    let nextName: String
    /// Direction of the last arrow tap: the new account pushes in from
    /// the trailing edge after «›», from the leading edge after «‹».
    let forward: Bool

    var count: Int { pages.count }

    /// Dots up to this many accounts, «3/9» beyond.
    static let maxDots = 7
    var showsDots: Bool { count <= Self.maxDots }
    /// «3/9» — 1-based.
    var counterText: String { "\(position + 1)/\(count)" }
}

/// What one «Счёт» entry shows: the account (or an empty state) and, on
/// the families with arrows, the pager.
struct AccountWidgetContent: Equatable, Sendable {
    let state: AccountWidgetState
    let pager: AccountWidgetPager?
}

/// The «Счёт» arrows' rules. Pure, so the timeline provider and the step
/// intent agree by construction (both read the same snapshot and the same
/// remembered steps).
enum AccountWidgetCarousel {
    /// Only the Home Screen families have room for ‹ › (Lock Screen
    /// widgets keep their layout).
    static func showsArrows(in family: WidgetFamily) -> Bool {
        family == .systemSmall || family == .systemMedium
    }

    /// Identifies "this widget" for the arrows: its configured account
    /// (or `default` when none is picked) and its family — a small and a
    /// medium widget of the same account move independently. WidgetKit
    /// gives an extension no per-instance id, so two widgets of the same
    /// family configured with the same account share a key and move
    /// together (accepted). Editing a widget to another account gives it
    /// a fresh key.
    static func widgetKey(configuredAccountId: String?, family: WidgetFamily) -> String {
        let account = configuredAccountId?.trimmingCharacters(in: .whitespaces).lowercased()
        let accountPart = (account?.isEmpty == false ? account : nil) ?? "default"
        return "\(accountPart)@\(familyKey(family))"
    }

    static func familyKey(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extraLarge"
        case .accessoryRectangular: "rectangular"
        case .accessoryInline: "inline"
        case .accessoryCircular: "circular"
        default: "other"
        }
    }

    /// The account shown: the remembered step while that account still
    /// exists, else the configured account, else the primary / first
    /// (`AccountWidgetSelection.resolve`). A deleted id silently falls back.
    static func shownAccount(
        in snapshot: SharedSnapshot?,
        configuredAccountId: String?,
        override: AccountWidgetOverride?
    ) -> SharedSnapshot.AccountItem? {
        let accounts = AccountWidgetSelection.choices(in: snapshot)
        if let override, let index = index(of: override.accountId, in: accounts) {
            return accounts[index]
        }
        return AccountWidgetSelection.resolve(id: configuredAccountId, in: snapshot)
    }

    /// The account before / after `id` in `accounts`, wrapping around both
    /// ways. nil when there is nothing to switch to (no accounts, one
    /// account). An id not in the list counts as the first account.
    static func neighbour(
        of id: String,
        in accounts: [SharedSnapshot.AccountItem],
        forward: Bool
    ) -> SharedSnapshot.AccountItem? {
        guard accounts.count > 1 else { return nil }
        let current = index(of: id, in: accounts) ?? 0
        let next = (current + (forward ? 1 : -1) + accounts.count) % accounts.count
        return accounts[next]
    }

    static func index(of id: String, in accounts: [SharedSnapshot.AccountItem]) -> Int? {
        accounts.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Everything one entry shows. The pager exists only on a family with
    /// arrows and with more than one account.
    static func content(
        snapshot: SharedSnapshot?,
        configuredAccountId: String?,
        family: WidgetFamily,
        overrides: [String: AccountWidgetOverride]
    ) -> AccountWidgetContent {
        guard let snapshot, snapshot.accounts != nil else {
            return AccountWidgetContent(state: .signedOut, pager: nil)
        }
        let key = widgetKey(configuredAccountId: configuredAccountId, family: family)
        let override = showsArrows(in: family) ? overrides[key] : nil
        guard let shown = shownAccount(in: snapshot, configuredAccountId: configuredAccountId, override: override) else {
            return AccountWidgetContent(state: .noAccounts, pager: nil)
        }
        let accounts = AccountWidgetSelection.choices(in: snapshot)
        guard showsArrows(in: family),
              let previous = neighbour(of: shown.id, in: accounts, forward: false),
              let next = neighbour(of: shown.id, in: accounts, forward: true),
              let position = index(of: shown.id, in: accounts)
        else {
            return AccountWidgetContent(state: .account(shown), pager: nil)
        }
        let pager = AccountWidgetPager(
            widgetKey: key,
            configuredAccountId: configuredAccountId,
            pages: accounts.map { AccountWidgetPager.Page(id: $0.id, colorHex: $0.colorHex) },
            position: position,
            currentName: shown.name,
            previousName: previous.name,
            nextName: next.name,
            forward: override?.forward ?? true
        )
        return AccountWidgetContent(state: .account(shown), pager: pager)
    }

    /// One arrow tap: the account after (or before) the one the widget
    /// shows now, remembered under its key. Relative to the stored state,
    /// not to what the tapped rendering showed, so two quick taps move two
    /// accounts. nil (nothing written) when there is nothing to switch to.
    static func step(
        widgetKey: String,
        configuredAccountId: String?,
        forward: Bool,
        snapshot: SharedSnapshot?,
        overrides: [String: AccountWidgetOverride]
    ) -> [String: AccountWidgetOverride]? {
        let accounts = AccountWidgetSelection.choices(in: snapshot)
        guard let shown = shownAccount(in: snapshot, configuredAccountId: configuredAccountId, override: overrides[widgetKey]),
              let target = neighbour(of: shown.id, in: accounts, forward: forward)
        else { return nil }
        var updated = overrides
        updated[widgetKey] = AccountWidgetOverride(accountId: target.id, forward: forward)
        return updated
    }

    /// Steps nobody can see any more: a key no placed widget has (the
    /// widget was removed or edited to another account — editing it back
    /// then starts on the configured account again) or an account that no
    /// longer exists. `liveKeys` nil = unknown → only the account check.
    static func pruned(
        _ overrides: [String: AccountWidgetOverride],
        liveKeys: Set<String>?,
        accountIds: Set<String>
    ) -> [String: AccountWidgetOverride] {
        let ids = Set(accountIds.map { $0.lowercased() })
        return overrides.filter { key, value in
            (liveKeys?.contains(key) ?? true) && ids.contains(value.accountId.lowercased())
        }
    }

    /// Keys of the «Счёт» widgets placed right now (families with arrows).
    /// nil when WidgetKit can't say — or when its answer doesn't include
    /// the widget asking (`ownKey`): an answer that misses the widget being
    /// rendered can't be trusted to drop other widgets' steps.
    static func liveKeys(
        configurations: [(family: WidgetFamily, configuredAccountId: String?)],
        ownKey: String
    ) -> Set<String>? {
        let keys = Set(configurations
            .filter { showsArrows(in: $0.family) }
            .map { widgetKey(configuredAccountId: $0.configuredAccountId, family: $0.family) })
        return keys.contains(ownKey) ? keys : nil
    }
}

/// The remembered steps, in the App Group defaults (the extension writes
/// them, the extension reads them; the app only clears them on sign-out).
/// One JSON value: `[widgetKey: AccountWidgetOverride]`.
enum AccountWidgetOverrideStore {
    static let defaultsKey = "widget.account.shownOverrides"

    /// The App Group suite (nil without the entitlement).
    static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedSnapshotStore.appGroupID)
    }

    static func load(from defaults: UserDefaults? = appGroupDefaults) -> [String: AccountWidgetOverride] {
        guard let data = defaults?.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AccountWidgetOverride].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ overrides: [String: AccountWidgetOverride], to defaults: UserDefaults? = appGroupDefaults) {
        guard let defaults else { return }
        if overrides.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Sign-out: the next user starts on their configured accounts.
    static func clear(in defaults: UserDefaults? = appGroupDefaults) {
        defaults?.removeObject(forKey: defaultsKey)
    }
}

/// «‹» / «›» on a «Счёт» widget. Runs without opening the app: remembers
/// the neighbouring account under the widget's key and returns — WidgetKit
/// reloads the widget after an interactive intent, and the provider then
/// shows that account.
struct AccountWidgetStepIntent: AppIntent {
    static let title: LocalizedStringResource = "widget.account.step.title"
    static let description = IntentDescription("widget.account.step.description")
    /// A widget button, not a Shortcuts action.
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "widget.account.step.widgetKey", default: "")
    var widgetKey: String

    /// The widget's configured account id; "" = none picked.
    @Parameter(title: "widget.account.step.configuredAccount", default: "")
    var configuredAccountId: String

    @Parameter(title: "widget.account.step.forward", default: true)
    var forward: Bool

    init() {}

    init(pager: AccountWidgetPager, forward: Bool) {
        self.widgetKey = pager.widgetKey
        self.configuredAccountId = pager.configuredAccountId ?? ""
        self.forward = forward
    }

    func perform() async throws -> some IntentResult {
        guard !widgetKey.isEmpty else { return .result() }
        let defaults = AccountWidgetOverrideStore.appGroupDefaults
        if let updated = AccountWidgetCarousel.step(
            widgetKey: widgetKey,
            configuredAccountId: configuredAccountId.isEmpty ? nil : configuredAccountId,
            forward: forward,
            snapshot: SharedSnapshotStore.load(),
            overrides: AccountWidgetOverrideStore.load(from: defaults)
        ) {
            AccountWidgetOverrideStore.save(updated, to: defaults)
        }
        return .result()
    }
}
