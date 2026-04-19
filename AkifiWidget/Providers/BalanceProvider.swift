import WidgetKit

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: SharedSnapshot.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = SnapshotTimelinePolicy.loadSnapshot()
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = SnapshotTimelinePolicy.loadSnapshot()
        completion(SnapshotTimelinePolicy.timeline(snapshot: snapshot))
    }
}
