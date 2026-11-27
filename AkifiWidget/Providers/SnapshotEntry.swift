import WidgetKit
import SwiftUI
import Foundation

/// Single shared `TimelineEntry` wrapper. All four widgets hold the same
/// snapshot payload — they just render different slices of it.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil = the app has written nothing usable (signed out, fresh install,
    /// unreadable / other-schema payload): the widget shows its empty
    /// state, never sample numbers (Y7).
    let snapshot: SharedSnapshot?
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

    static func timeline(snapshot: SharedSnapshot?, now: Date = Date()) -> Timeline<SnapshotEntry> {
        let next = now.addingTimeInterval(refreshInterval)
        guard let snapshot else {
            // Nothing to roll over; the app reloads the timeline when it
            // writes a snapshot.
            return Timeline(entries: [SnapshotEntry(date: now, snapshot: nil)], policy: .after(next))
        }
        let cal = SharedSnapshot.dayCalendar
        var entries = [SnapshotEntry(date: now, snapshot: snapshot.rolledOver(to: now))]
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            entries.append(SnapshotEntry(date: midnight, snapshot: snapshot.rolledOver(to: midnight)))
        }
        return Timeline(entries: entries, policy: .after(next))
    }

    /// The stored snapshot, or nil — never the gallery placeholder.
    static func loadSnapshot() -> SharedSnapshot? {
        SharedSnapshotStore.load()
    }

    /// For `getSnapshot` — the current state, already rolled over to now.
    /// The gallery preview (`isPreview`) gets sample data when there is no
    /// snapshot; a home-screen widget gets the empty state.
    static func currentEntry(isPreview: Bool, now: Date = Date()) -> SnapshotEntry {
        let shown = SharedSnapshot.forDisplay(stored: loadSnapshot(), isPreview: isPreview)
        return SnapshotEntry(date: now, snapshot: shown?.rolledOver(to: now))
    }

    /// `placeholder(in:)` — the redacted gallery / loading placeholder.
    static func placeholderEntry() -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: SharedSnapshot.placeholder)
    }
}

// MARK: - Empty state (Y7)

/// What every widget shows when the app has written no snapshot: an
/// explicit «Откройте Akifi» instead of made-up balances. Tap opens the app.
struct WidgetEmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringResource
    var deepLink: URL? = URL(string: "akifi://home")

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                .widgetLabel {
                    Text(LocalizedStringResource("widget.empty.title", defaultValue: "Откройте Akifi"))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(LocalizedStringResource("widget.empty.title", defaultValue: "Откройте Akifi"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedStringResource(
                        "widget.empty.subtitle",
                        defaultValue: "Войдите, чтобы здесь появились ваши данные"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .widgetURL(deepLink)
    }
}
