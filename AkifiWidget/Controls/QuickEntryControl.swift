import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action button control: one tap opens
/// Akifi straight into quick entry (`akifi://quick-add?mode=expense`).
///
/// The control only opens the app — the entry is written by the app's
/// quick-entry sheet, through the same path as every other save.
struct QuickEntryControl: ControlWidget {
    static let kind = "ru.akifi.app.widget.quickEntry"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenQuickEntryIntent(mode: .expense)) {
                Label {
                    Text(LocalizedStringResource("control.quickEntry.label", defaultValue: "Расход"))
                } icon: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .displayName(LocalizedStringResource("control.quickEntry.displayName", defaultValue: "Быстрый расход"))
        .description(LocalizedStringResource("control.quickEntry.description", defaultValue: "Открывает Akifi сразу на вводе расхода"))
    }
}
