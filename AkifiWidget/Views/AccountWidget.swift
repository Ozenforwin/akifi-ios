import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct AccountWidgetEntry: TimelineEntry {
    let date: Date
    let content: AccountWidgetContent
}

/// «Счёт»: the configured account from the App Group snapshot — or, after
/// the ‹ › arrows were used, the account they switched to
/// (`AccountWidgetCarousel`). Same cadence as the other widgets
/// (`SnapshotTimelinePolicy`): the app reloads this kind when account data
/// changes, WidgetKit reloads it after an arrow tap; an extra entry at
/// midnight zeroes the month figures when a new month starts while the app
/// is closed.
struct AccountWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AccountWidgetEntry {
        AccountWidgetEntry(
            date: Date(),
            content: AccountWidgetCarousel.content(
                snapshot: .placeholder, configuredAccountId: nil, family: context.family, overrides: [:]
            )
        )
    }

    func snapshot(for configuration: AccountWidgetIntent, in context: Context) async -> AccountWidgetEntry {
        let now = Date()
        let shown = SharedSnapshot.forDisplay(stored: SnapshotTimelinePolicy.loadSnapshot(), isPreview: context.isPreview)
        // The gallery preview shows the configured account, never a step.
        let overrides = context.isPreview ? [:] : AccountWidgetOverrideStore.load()
        return AccountWidgetEntry(
            date: now,
            content: AccountWidgetCarousel.content(
                snapshot: shown?.rolledOver(to: now),
                configuredAccountId: configuration.account?.id,
                family: context.family,
                overrides: overrides
            )
        )
    }

    func timeline(for configuration: AccountWidgetIntent, in context: Context) async -> Timeline<AccountWidgetEntry> {
        let snapshot = SnapshotTimelinePolicy.loadSnapshot()
        let configuredId = configuration.account?.id
        let overrides = await Self.prunedOverrides(
            snapshot: snapshot,
            ownKey: AccountWidgetCarousel.widgetKey(configuredAccountId: configuredId, family: context.family)
        )
        let base = SnapshotTimelinePolicy.timeline(snapshot: snapshot)
        let entries = base.entries.map { entry in
            AccountWidgetEntry(
                date: entry.date,
                content: AccountWidgetCarousel.content(
                    snapshot: entry.snapshot,
                    configuredAccountId: configuredId,
                    family: context.family,
                    overrides: overrides
                )
            )
        }
        return Timeline(entries: entries, policy: base.policy)
    }

    /// The remembered arrow steps minus the ones nobody can see any more:
    /// deleted accounts, and keys of widgets that were removed or edited to
    /// another account (so editing a widget back starts on its configured
    /// account). Written back only when something was dropped.
    private static func prunedOverrides(snapshot: SharedSnapshot?, ownKey: String) async -> [String: AccountWidgetOverride] {
        let stored = AccountWidgetOverrideStore.load()
        guard !stored.isEmpty, let accounts = snapshot?.accounts else { return stored }
        let configurations = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        let liveKeys = AccountWidgetCarousel.liveKeys(
            configurations: configurations
                .filter { $0.kind == AkifiWidgetKind.account }
                .map { ($0.family, $0.widgetConfigurationIntent(of: AccountWidgetIntent.self)?.account?.id) },
            ownKey: ownKey
        )
        let pruned = AccountWidgetCarousel.pruned(stored, liveKeys: liveKeys, accountIds: Set(accounts.map(\.id)))
        if pruned != stored { AccountWidgetOverrideStore.save(pruned) }
        return pruned
    }
}

// MARK: - Widget

/// Reads the family and rendering mode WidgetKit puts in the environment
/// and hands them to the shared view (tests pass them in directly).
private struct AccountWidgetEntryView: View {
    let entry: AccountWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        AccountWidgetView(
            state: entry.content.state,
            family: family,
            renderingMode: renderingMode,
            pager: entry.content.pager
        )
        .containerBackground(for: .widget) {
            AccountWidgetBackground(state: entry.content.state, renderingMode: renderingMode)
        }
    }
}

struct AccountWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: AkifiWidgetKind.account,
            intent: AccountWidgetIntent.self,
            provider: AccountWidgetProvider()
        ) { entry in
            AccountWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(
            Text(LocalizedStringResource("widget.account.displayName", defaultValue: "Счёт"))
        )
        .description(
            Text(LocalizedStringResource(
                "widget.account.description",
                defaultValue: "Баланс счёта и быстрый ввод операций"
            ))
        )
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}
