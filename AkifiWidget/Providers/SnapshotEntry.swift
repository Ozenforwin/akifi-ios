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
///
/// Y11: the app computes the "today" fields only while it runs. Every entry
/// renders the snapshot rolled over to the entry's own date, and the timeline
/// carries an extra entry at the next midnight — so at 00:00 the widget
/// stops showing yesterday's spending as "today" even if the app never ran.
enum SnapshotTimelinePolicy {
    /// How far into the future to schedule refreshes with no app activity.
    /// WidgetKit will honour this as a hint; the real cadence is driven by
    /// budgets from the system.
    static let refreshInterval: TimeInterval = 30 * 60

    static func timeline(snapshot: SharedSnapshot, now: Date = Date()) -> Timeline<SnapshotEntry> {
        let next = now.addingTimeInterval(refreshInterval)
        let cal = SharedSnapshot.dayCalendar
        var entries = [SnapshotEntry(date: now, snapshot: snapshot.rolledOver(to: now))]
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            entries.append(SnapshotEntry(date: midnight, snapshot: snapshot.rolledOver(to: midnight)))
        }
        return Timeline(entries: entries, policy: .after(next))
    }

    static func loadSnapshot() -> SharedSnapshot {
        SharedSnapshotStore.load() ?? SharedSnapshot.placeholder
    }

    /// For `getSnapshot` — the current state, already rolled over to now.
    static func currentEntry(now: Date = Date()) -> SnapshotEntry {
        SnapshotEntry(date: now, snapshot: loadSnapshot().rolledOver(to: now))
    }
}
