import WidgetKit

struct DaySummaryProvider: TimelineProvider {
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
