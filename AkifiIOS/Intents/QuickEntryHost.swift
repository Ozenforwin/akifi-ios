import Foundation

/// Bridge from App Intents (Siri, Shortcuts, Spotlight) to the app's ONE
/// `DataStore`.
///
/// App Intents declared in the app target run inside the app process —
/// launched in the background when the app isn't running. They must not
/// build a second `DataStore` (two offline queues on the same files, two
/// caches); `AppViewModel.init` attaches the instance the UI uses, and
/// intents borrow it through `prepare()`.
@MainActor
final class QuickEntryHost {
    static let shared = QuickEntryHost()

    enum Unavailable: Error, Equatable {
        /// No `AppViewModel` yet (should not happen: `App.init` runs first).
        case notRunning
        /// No valid session — the user has to sign in in the app.
        case signedOut
        /// Nothing cached yet (fresh install, first sign-in still loading).
        case noData
    }

    private(set) weak var appViewModel: AppViewModel?

    /// Session seam — tests replace it. Production: a session whose token
    /// is valid (refreshed if needed), the same check the data store uses
    /// before talking to the server (Y2).
    var sessionUserId: @MainActor () async -> String? = {
        await SupabaseManager.shared.validSessionUserId()
    }

    init() {}

    func attach(_ app: AppViewModel) {
        appViewModel = app
    }

    /// The live app state, ready for a write outside the UI: a valid
    /// session, and the signed-in user's own cache on screen (the cache
    /// load drops a cache that belongs to someone else — Y3).
    func prepare() async -> Result<AppViewModel, Unavailable> {
        guard let app = appViewModel else { return .failure(.notRunning) }
        guard await sessionUserId() != nil else { return .failure(.signedOut) }
        if !app.dataStore.hasDisplayableData {
            await app.dataStore.loadCachedDataIfNeeded()
        }
        guard !app.dataStore.accounts.isEmpty else { return .failure(.noData) }
        return .success(app)
    }

    /// Snapshot for entity queries (category / account pickers in
    /// Shortcuts). Nil when the app can't answer.
    func context() async -> QuickEntryContext? {
        guard case .success(let app) = await prepare() else { return nil }
        return QuickEntryContext(dataStore: app.dataStore, currencyManager: app.currencyManager)
    }
}
