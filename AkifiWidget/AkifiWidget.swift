import WidgetKit
import SwiftUI

/// WidgetBundle — the entry-point that exposes all four widgets to iOS's
/// Widget Gallery.
///
/// Each widget is a standalone `Widget` conforming type defined in the
/// adjacent files; this bundle is purely an aggregator. Adding a new
/// widget = listing it here + providing a `Provider` and a `View`.
@main
struct AkifiWidgetBundle: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
        DailyLimitWidget()
        StreakWidget()
        DaySummaryWidget()
    }
}
