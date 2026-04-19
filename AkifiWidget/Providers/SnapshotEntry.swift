import WidgetKit
import Foundation

/// Single shared `TimelineEntry` wrapper. All four widgets hold the same
/// snapshot payload — they just render different slices of it.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot
}

/// Shared timeline generation — refresh every 30 minutes. WidgetKit coalesces
/// this with `WidgetCenter.reloadAllTimelines()` triggered by the main app
/// after any data mutation, so users see fresh numbers almost immediately
/// after adding a transaction.
enum SnapshotTimelinePolicy {
    /// How far into the future to schedule refreshes with no app activity.
    /// WidgetKit will honour this as a hint; the real cadence is driven by
    /// budgets from the system.
    static let refreshInterval: TimeInterval = 30 * 60

    static func timeline(snapshot: SharedSnapshot) -> Timeline<SnapshotEntry> {
        let now = Date()
        let next = now.addingTimeInterval(refreshInterval)
        return Timeline(
            entries: [SnapshotEntry(date: now, snapshot: snapshot)],
            policy: .after(next)
        )
    }

    static func loadSnapshot() -> SharedSnapshot {
        SharedSnapshotStore.load() ?? SharedSnapshot.placeholder
    }
}
