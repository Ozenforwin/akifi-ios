import WidgetKit

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotTimelinePolicy.placeholderEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotTimelinePolicy.currentEntry(isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = SnapshotTimelinePolicy.loadSnapshot()
        completion(SnapshotTimelinePolicy.timeline(snapshot: snapshot))
    }
}
