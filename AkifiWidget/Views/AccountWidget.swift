import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct AccountWidgetEntry: TimelineEntry {
    let date: Date
    let state: AccountWidgetState
}

/// «Счёт»: the configured account from the App Group snapshot. Same
/// cadence as the other widgets (`SnapshotTimelinePolicy`): the app reloads
/// this kind when account data changes; an extra entry at midnight zeroes
/// the month figures when a new month starts while the app is closed.
struct AccountWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AccountWidgetEntry {
        AccountWidgetEntry(date: Date(), state: AccountWidgetState.resolve(snapshot: .placeholder, accountId: nil))
    }

    func snapshot(for configuration: AccountWidgetIntent, in context: Context) async -> AccountWidgetEntry {
        let now = Date()
        let shown = SharedSnapshot.forDisplay(stored: SnapshotTimelinePolicy.loadSnapshot(), isPreview: context.isPreview)
        return AccountWidgetEntry(
            date: now,
            state: AccountWidgetState.resolve(snapshot: shown?.rolledOver(to: now), accountId: configuration.account?.id)
        )
    }

    func timeline(for configuration: AccountWidgetIntent, in context: Context) async -> Timeline<AccountWidgetEntry> {
        let base = SnapshotTimelinePolicy.timeline(snapshot: SnapshotTimelinePolicy.loadSnapshot())
        let entries = base.entries.map { entry in
            AccountWidgetEntry(
                date: entry.date,
                state: AccountWidgetState.resolve(snapshot: entry.snapshot, accountId: configuration.account?.id)
            )
        }
        return Timeline(entries: entries, policy: base.policy)
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
        AccountWidgetView(state: entry.state, family: family, renderingMode: renderingMode)
            .containerBackground(for: .widget) {
                AccountWidgetBackground(state: entry.state, renderingMode: renderingMode)
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
