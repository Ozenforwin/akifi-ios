import SwiftUI
import WidgetKit

// MARK: - Timeline

struct AllAccountsWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
}

/// «Все счета»: every money account of the App Group snapshot with its
/// balance. Same cadence as the other widgets (`SnapshotTimelinePolicy`);
/// the app reloads this kind when the accounts, their balances or the
/// base-currency total change.
struct AllAccountsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllAccountsWidgetEntry {
        AllAccountsWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AllAccountsWidgetEntry) -> Void) {
        let entry = SnapshotTimelinePolicy.currentEntry(isPreview: context.isPreview)
        completion(AllAccountsWidgetEntry(date: entry.date, snapshot: entry.snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AllAccountsWidgetEntry>) -> Void) {
        let base = SnapshotTimelinePolicy.timeline(snapshot: SnapshotTimelinePolicy.loadSnapshot())
        completion(Timeline(
            entries: base.entries.map { AllAccountsWidgetEntry(date: $0.date, snapshot: $0.snapshot) },
            policy: base.policy
        ))
    }
}

// MARK: - Widget

private struct AllAccountsWidgetEntryView: View {
    let entry: AllAccountsWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        AllAccountsWidgetView(
            state: AllAccountsWidgetSelection.state(snapshot: entry.snapshot, family: family),
            family: family,
            renderingMode: renderingMode
        )
        .containerBackground(for: .widget) {
            Color(.secondarySystemGroupedBackground)
        }
    }
}

struct AllAccountsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AkifiWidgetKind.accounts, provider: AllAccountsWidgetProvider()) { entry in
            AllAccountsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(
            Text(LocalizedStringResource("widget.accounts.displayName", defaultValue: "Все счета"))
        )
        .description(
            Text(LocalizedStringResource("widget.accounts.description", defaultValue: "Балансы всех счетов"))
        )
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
