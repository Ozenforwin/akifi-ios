import WidgetKit
import SwiftUI

/// WidgetBundle — the entry-point that exposes the widgets to iOS's Widget
/// Gallery and the quick-entry control to Control Center.
///
/// Each widget is a standalone `Widget` conforming type defined in the
/// adjacent files; this bundle is purely an aggregator. Adding a new
/// widget = listing it here + providing a `Provider` and a `View` + its
/// kind in `AkifiWidgetKind` (the app reloads widgets by kind).
@main
struct AkifiWidgetBundle: WidgetBundle {
    var body: some Widget {
        AccountWidget()
        AllAccountsWidget()
        QuickAddWidget()
        BalanceWidget()
        DailyLimitWidget()
        StreakWidget()
        DaySummaryWidget()
        QuickEntryControl()
    }
}
