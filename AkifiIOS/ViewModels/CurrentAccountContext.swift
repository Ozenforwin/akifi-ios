import Foundation

/// Tracks which account the user is currently "looking at" in the UI so the
/// global FAB can pre-fill the Account picker on the new-transaction sheet.
///
/// Writers:
/// - `HomeTabView` — mirrors the carousel's selected account.
/// - `SharedAccountDetailView` — overrides with the pushed account, then
///   restores the previous value on dismiss.
///
/// Readers:
/// - `MainTabView` — forwards `accountId` into `SheetDestination.expense`/
///   `.income` only while the Home tab is active. On other tabs the FAB
///   resolves to `nil` (no contextual account).
@Observable @MainActor
final class CurrentAccountContext {
    /// `nil` means "no contextual account" — the form should fall back to
    /// the user's default behavior (no account preselected).
    var accountId: String?
}
