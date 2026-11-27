import SwiftUI
import WidgetKit

/// «Быстрая запись»: «Расход», «Доход», the mic and — medium — up to three
/// «Повторить» items. The buttons work without a snapshot too (they only
/// open the app); the «Повторить» list needs the app to have written one.
struct QuickAddProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotTimelinePolicy.placeholderEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotTimelinePolicy.currentEntry(isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(SnapshotTimelinePolicy.timeline(snapshot: SnapshotTimelinePolicy.loadSnapshot()))
    }
}

private struct QuickAddWidgetEntryView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        QuickAddWidgetView(repeatItems: entry.snapshot?.repeatItems, family: family, renderingMode: renderingMode)
            .containerBackground(for: .widget) {
                Color(.secondarySystemGroupedBackground)
            }
    }
}

struct QuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AkifiWidgetKind.quickAdd, provider: QuickAddProvider()) { entry in
            QuickAddWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(
            Text(LocalizedStringResource("widget.quickAdd.displayName", defaultValue: "Быстрая запись"))
        )
        .description(
            Text(LocalizedStringResource(
                "widget.quickAdd.description",
                defaultValue: "Расход, доход или голосом — в одно касание"
            ))
        )
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
        .contentMarginsDisabled()
    }
}
