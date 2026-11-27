import Foundation
import Observation

/// Where a «+» action leads (pure — `MainTabView` performs it).
enum FABRoute: Equatable {
    /// The quick-entry sheet. `accountId` only when the user is looking at
    /// a specific account (see `QuickEntryCoordinator.pinnedAccountId`).
    case quickEntry(mode: QuickEntryLaunchMode, categoryId: String?, accountId: String?)
    case transfer
    case receipt
    case debt(DebtAction)
}

/// One open quick-entry sheet (the `.sheet(item:)` item).
struct QuickEntryPresentation: Identifiable {
    let id = UUID()
    let request: QuickEntryRequest
    let model: QuickEntrySheetModel
}

/// Presentation state of quick entry inside `MainTabView`: which sheet is
/// open, the «Записано · Отменить» toast, and the hand-over to the full
/// form («Подробнее»).
///
/// Entry points:
/// - the «+» tap / long-press menu → `route(_:selectedTab:contextAccountId:accounts:)`;
/// - `QuickEntryInbox` (links, Home-screen quick actions, Control Center,
///   Siri) → `takeInboxRequest(from:otherSheetPresented:now:)`;
/// - the assistant's «add expense / income».
@Observable @MainActor
final class QuickEntryCoordinator {

    /// The open sheet; nil = closed.
    var presented: QuickEntryPresentation?
    /// The last saved entry while its undo toast is up.
    private(set) var toast: QuickEntrySaved?

    @ObservationIgnored private var pendingDetails: TransactionFormPrefill?

    /// Speech seam: a fresh recognizer per sheet.
    @ObservationIgnored var makeSpeech: @MainActor () -> SpeechQuickEntry = { SpeechQuickEntry() }
    /// Submitter seam (tests, the DEBUG UI harness).
    @ObservationIgnored var configureSubmitter: (@MainActor (inout QuickEntrySubmitter) -> Void)?

    init() {
        #if DEBUG
        UIHarnessQuickEntry.configure(self)
        #endif
    }

    // MARK: - Routing

    /// What a «+» action opens. Income / expense go to quick entry; the
    /// full form stays one tap away there («Подробнее»).
    static func route(
        _ action: FABAction,
        selectedTab: AppTab,
        contextAccountId: String?,
        accounts: [Account]
    ) -> FABRoute {
        let pinned = pinnedAccountId(selectedTab: selectedTab, contextAccountId: contextAccountId, accounts: accounts)
        switch action {
        case .expense(let categoryId):
            return .quickEntry(mode: .expense, categoryId: categoryId, accountId: pinned)
        case .income(let categoryId):
            return .quickEntry(mode: .income, categoryId: categoryId, accountId: pinned)
        case .transfer:
            return .transfer
        case .receipt:
            return .receipt
        case .debt(let action):
            return .debt(action)
        }
    }

    /// The account the user is looking at, when that is a choice: a Home
    /// carousel moved off its first card, or a pushed account screen of
    /// another account. The carousel at rest is not a choice — quick entry
    /// then uses its own default (the account last used for this type).
    static func pinnedAccountId(selectedTab: AppTab, contextAccountId: String?, accounts: [Account]) -> String? {
        guard selectedTab == .home, let id = contextAccountId,
              accounts.contains(where: { $0.id == id }) else { return nil }
        return id == accounts.first?.id ? nil : id
    }

    // MARK: - Presenting

    /// Opens the sheet for `request` with a fresh snapshot of the store.
    func present(_ request: QuickEntryRequest, dataStore: DataStore, currencyManager: CurrencyManager?) {
        let context = QuickEntryContext(dataStore: dataStore, currencyManager: currencyManager)
        var submitter = QuickEntrySubmitter(dataStore: dataStore, currencyManager: currencyManager)
        configureSubmitter?(&submitter)
        let model = QuickEntrySheetModel(context: context, request: request, submitter: submitter, speech: makeSpeech())
        presented?.model.cancelVoice()
        presented = QuickEntryPresentation(request: request, model: model)
    }

    /// The inbox's waiting request, unless another sheet of the shell is up
    /// (two sheets can't be presented at once — it stays waiting and is
    /// taken when that sheet closes). Stale requests are dropped.
    func takeInboxRequest(from inbox: QuickEntryInbox, otherSheetPresented: Bool, now: Date = Date()) -> QuickEntryRequest? {
        guard inbox.pending != nil, !otherSheetPresented else { return nil }
        return inbox.consume(now: now)
    }

    // MARK: - Leaving the sheet

    func didSave(_ saved: QuickEntrySaved) {
        presented = nil
        toast = saved
    }

    /// «Подробнее»: close the sheet, then open the form with the draft.
    func openDetails() {
        guard let model = presented?.model else { return }
        model.cancelVoice()
        pendingDetails = model.formPrefill
        presented = nil
    }

    /// The sheet finished its dismissal: the form to open, if «Подробнее»
    /// asked for one.
    func takePendingDetails() -> TransactionFormPrefill? {
        defer { pendingDetails = nil }
        return pendingDetails
    }

    // MARK: - Toast

    func dismissToast(id: UUID) {
        if toast?.id == id { toast = nil }
    }

    /// «Отменить»: deletes the entry through the normal delete path (online,
    /// or the offline queue — a queued create is cancelled there).
    @discardableResult
    func undo(_ saved: QuickEntrySaved, dataStore: DataStore) async -> Bool {
        dismissToast(id: saved.id)
        // The live row (a queued placeholder may have been replaced by the
        // server row since); gone already = nothing to undo.
        guard let row = dataStore.transactions.first(where: { $0.id == saved.transaction.id }) else { return false }
        let deleted = await dataStore.deleteTransaction(row)
        if deleted {
            AnalyticsService.logEvent("quick_entry_undo", params: ["method": saved.method.rawValue])
        }
        return deleted
    }
}
