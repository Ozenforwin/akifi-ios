import SwiftUI

/// Legacy entry point kept for backward compatibility with the Sunday
/// auto-prompt notification flow. In Journal v2, it simply wraps the
/// unified `JournalNoteFormView` with `.reflection` as the initial type.
///
/// Existing call sites:
/// - `HomeTabView` -> opens Journal tab via NavigationLink (no direct use)
/// - Scheduler-triggered reflection reminder (future)
struct JournalReflectionFormView: View {
    let viewModel: JournalViewModel
    let dataStore: DataStore

    var body: some View {
        JournalNoteFormView(
            viewModel: viewModel,
            initialType: .reflection
        )
    }
}
